import Foundation

extension Ledger {
    /// Capacity backpressure does not spend an attempt or manufacture a failure.
    public func releaseClaim(jobID: UUID) throws {
        try transaction {
            let job = try loadJob(jobID)
            guard job.state == .checking, try !hasRetainedTransfers(jobID: jobID) else { throw CoreError.invalidTransition }
            try db.execute("UPDATE jobs SET state='reconciling' WHERE id=?", [jobID.sql])
        }
    }
    private func moveToQueueEnd(_ jobID: UUID) throws {
        let last = try db.rows("SELECT COALESCE(MAX(seq),0) AS n FROM jobs").first!.int("n")
        guard last < Int64.max else { throw CoreError.invalidContract }
        try db.execute("UPDATE jobs SET seq=? WHERE id=?", [.integer(last + 1), jobID.sql])
    }
    public func recordSubmission(jobID: UUID, resourceID: UUID, transferID: UUID, runID: UUID) throws {
        try transaction {
            let job = try loadJob(jobID)
            guard job.destination.provider == .google, job.state == .uploading,
                  let resource = job.plan.resources.first(where: { $0.id == resourceID }),
                  let checkpoint = try providerCheckpoint(destinationID: job.destination.id, tag: resource.tag),
                  checkpoint.jobID == jobID, checkpoint.transferID == transferID,
                  checkpoint.phase == .transferring, !checkpoint.inputsTerminal,
                  try retainedTransferIDs(destinationID: job.destination.id).contains(transferID) else { throw CoreError.recoveryRequired }
            try record(.setupTrace, context: EventContext(runID: runID, origin: .google,
                destinationID: job.destination.id, jobID: jobID, resourceID: resourceID,
                cycleID: job.cycleID, attempt: job.attempts,
                diagnostic: DiagnosticDetail(stage: .googleTransferQueued, status: .succeeded, correlationID: transferID)), decision: .proceed)
        }
    }
    private func resumableAttempt(_ job: JobRecord) throws -> Bool {
        try !db.rows("SELECT number FROM attempts WHERE job_id=? AND cycle=? AND number=? AND ended IS NULL AND suspended=1", [job.id.sql, job.cycleID.sql, .integer(Int64(job.attempts))]).isEmpty
    }
    public func canRun(_ destinationID: UUID, now: Date = Date()) throws -> Bool {
        guard let row = try db.rows("SELECT enabled,selected,recovered,blocked,resume_at FROM destinations WHERE id=?", [destinationID.sql]).first else { return false }
        guard row.int("enabled") == 1, row.int("selected") == 1, row.int("recovered") == 1 else { return false }
        if case .blob = row.values["blocked"] {
            guard let date = row.double("resume_at"), date <= now.timeIntervalSince1970 else { return false }
        }
        return true
    }
    /// One worker per provider; cursor-free indexed claim. Retry delays never hold
    /// up the next ready job. Only current scan/current coverage bindings execute.
    public func claimNext(destinationID: UUID, runID: UUID, now: Date = Date()) throws -> JobRecord? {
        try transaction {
            guard try canRun(destinationID, now: now) else { return nil }
            try db.execute("UPDATE jobs SET state='reconciling' WHERE destination_id=? AND state='waiting' AND retry_at<=?", [destinationID.sql, now.sql])
            try db.execute("UPDATE jobs SET state='reconciling' WHERE destination_id=? AND state='waiting' AND EXISTS(SELECT 1 FROM destinations d WHERE d.id=? AND d.blocked IS NOT NULL AND d.resume_at<=?)", [destinationID.sql, destinationID.sql, now.sql])
            try db.execute("UPDATE destinations SET blocked=NULL,resume_at=NULL WHERE id=? AND resume_at<=?", [destinationID.sql, now.sql])
            guard let row = try db.rows("""
                SELECT j.id FROM jobs j WHERE j.destination_id=?
                AND j.state IN ('checking','reconciling','delayed','ready')
                AND (j.retry_at IS NULL OR j.retry_at<=?)
                AND NOT EXISTS(SELECT 1 FROM transfers t WHERE t.job_id=j.id)
                AND EXISTS(SELECT 1 FROM aliases x JOIN assets a ON a.id=x.asset_id
                    JOIN scans s ON s.id=a.scan_id WHERE x.job_id=j.id AND s.complete=1
                    AND a.scan_id=(SELECT value FROM meta WHERE key='scan'))
                ORDER BY j.seq LIMIT 1
                """, [destinationID.sql, now.sql]).first,
                  let id = UUID(uuidString: try row.string("id")) else { return nil }
            let previous = try loadJob(id)
            try db.execute("UPDATE jobs SET state='checking',retry_at=NULL WHERE id=?", [id.sql])
            try db.execute("UPDATE obligations SET status='unknown' WHERE job_id=? AND status!='confirmed'", [id.sql])
            try record(.remoteCheck, context: context(previous, runID: runID), decision: .reconcile, from: previous.state, to: .checking)
            return try loadJob(id)
        }
    }
    public func applyPresence(_ presence: RemotePresence, jobID: UUID, resourceID: UUID, runID: UUID) throws {
        try transaction {
            let job = try loadJob(jobID)
            if job.state == .confirmed { return }
            guard job.state == .checking, let resource = job.plan.resources.first(where: { $0.id == resourceID }) else { throw CoreError.invalidTransition }
            switch presence {
            case .present(let receipt): try commitReceipt(receipt, job: job, resource: resource, runID: runID)
            case .verifiedAbsent:
                try db.execute("UPDATE obligations SET status='absent' WHERE job_id=? AND resource_id=? AND status!='confirmed'", [jobID.sql, resourceID.sql])
                try record(.remoteCheck, context: context(job, runID: runID, resource: resourceID), decision: .proceed)
            case .unknown(let error):
                try moveToQueueEnd(jobID)
                try storeFailure(error, job: job)
                let retry = try inspectionDeadline(error, job: job)
                try db.execute("UPDATE jobs SET state='waiting',failure=?,retry_at=? WHERE id=?", [try db.encode(error), retry?.sql ?? .null, jobID.sql])
                try record(.remoteCheck, context: context(job, runID: runID, resource: resourceID), severity: .warning, decision: .reconcile, from: job.state, to: .waiting, failure: error)
                if retry != nil { try record(.retryScheduled, context: context(job, runID: runID), decision: .reconcile) }
            case .destinationBlocked(let error, let resumeAt):
                try storeFailure(error, job: job)
                try db.execute("UPDATE jobs SET state='waiting',failure=?,retry_at=NULL WHERE id=?", [try db.encode(error), jobID.sql])
                try db.execute("UPDATE destinations SET blocked=?,resume_at=? WHERE id=?", [try db.encode(error), resumeAt?.sql ?? .null, job.destination.id.sql])
                try record(.remoteCheck, context: context(job, runID: runID, resource: resourceID), severity: .error, decision: .wait, from: job.state, to: .waiting, failure: error)
            }
        }
    }
    public func finishChecks(jobID: UUID, runID: UUID) throws -> JobRecord {
        try transaction {
            let job = try loadJob(jobID)
            if job.state == .confirmed || job.state == .waiting { return job }
            guard job.state == .checking else { throw CoreError.invalidTransition }
            let unknown = try db.rows("SELECT COUNT(*) AS n FROM obligations WHERE job_id=? AND status NOT IN ('absent','confirmed')", [jobID.sql]).first!.int("n")
            guard unknown == 0 else { throw CoreError.recoveryRequired }
            let resumable = try resumableAttempt(job)
            if job.attempts >= 3 && !resumable {
                try db.execute("UPDATE jobs SET state='failed' WHERE id=?", [jobID.sql])
                try record(.exhausted, context: context(job, runID: runID), severity: .error, decision: .skip, from: job.state, to: .failed)
            } else {
                try db.execute("UPDATE jobs SET state='ready' WHERE id=?", [jobID.sql])
            }
            return try loadJob(jobID)
        }
    }
    public func beginAttempt(jobID: UUID, runID: UUID) throws -> JobRecord {
        try transaction {
            let job = try loadJob(jobID)
            let resumed = try resumableAttempt(job)
            guard job.state == .ready, job.attempts < 3 || resumed, try canRun(job.destination.id) else { throw CoreError.invalidTransition }
            try db.execute("UPDATE jobs SET state='uploading',attempts=attempts+? WHERE id=?", [.integer(resumed ? 0 : 1), jobID.sql])
            let started = try loadJob(jobID)
            if resumed {
                try db.execute("UPDATE attempts SET suspended=0 WHERE job_id=? AND cycle=? AND number=?", [jobID.sql, started.cycleID.sql, .integer(Int64(started.attempts))])
            } else {
                try db.execute("INSERT INTO attempts(job_id,cycle,number,started) VALUES(?,?,?,?)", [jobID.sql, started.cycleID.sql, .integer(Int64(started.attempts)), Date().sql])
            }
            try record(.attemptStart, context: context(started, runID: runID), decision: .proceed, from: .ready, to: .uploading)
            return started
        }
    }
    /// Commit uncertainty BEFORE calling any adapter that may send bytes. A crash
    /// between this commit and remote confirmation requires reconciliation.
    public func willSend(jobID: UUID, resourceID: UUID, runID: UUID) throws {
        try transaction {
            let job = try loadJob(jobID)
            guard job.state == .uploading, try canRun(job.destination.id) else { throw CoreError.invalidTransition }
            try db.execute("UPDATE obligations SET status='sending' WHERE job_id=? AND resource_id=? AND status='absent'", [jobID.sql, resourceID.sql])
            guard db.changes == 1 else { throw CoreError.recoveryRequired }
            try record(.transferStart, context: context(job, runID: runID, resource: resourceID), decision: .proceed)
        }
    }
    public func confirm(_ receipt: RemoteReceipt, jobID: UUID, resourceID: UUID, runID: UUID? = nil) throws {
        try transaction {
            let job = try loadJob(jobID)
            guard let resource = job.plan.resources.first(where: { $0.id == resourceID }) else { throw CoreError.invalidContract }
            // Delayed callbacks address the immutable original job/destination.
            // They may settle old history while the UI shows a new mapping.
            try commitReceipt(receipt, job: job, resource: resource, runID: runID)
        }
    }
    func commitReceipt(_ receipt: RemoteReceipt, job: JobRecord, resource: ResourceRequirement, runID: UUID?) throws {
        guard receipt.destinationID == job.destination.id, receipt.tag == resource.tag,
              !receipt.opaqueReference.isEmpty, receipt.opaqueReference.count <= 64 * 1024 else { throw CoreError.invalidContract }
        // Preserve evidence that this installation uploaded the content when a
        // later lookup rediscovers it; do not silently reclassify it as preexisting.
        let previous = try db.rows("SELECT body FROM receipts WHERE destination_id=? AND tag=?", [receipt.destinationID.sql, .text(receipt.tag)]).first.map { try db.decode(RemoteReceipt.self, $0, "body") }
        let stored = previous?.kind == .uploaded ? previous! : receipt
        try db.execute("INSERT INTO receipts(destination_id,tag,kind,body,confirmed_at) VALUES(?,?,?,?,?) ON CONFLICT(destination_id,tag) DO UPDATE SET kind=excluded.kind,body=excluded.body,confirmed_at=excluded.confirmed_at", [stored.destinationID.sql, .text(stored.tag), .text(stored.kind.rawValue), try db.encode(stored), Date().sql])
        try db.execute("UPDATE obligations SET status='confirmed' WHERE job_id=? AND resource_id=?", [job.id.sql, resource.id.sql])
        let missing = try db.rows("SELECT COUNT(*) AS n FROM obligations WHERE job_id=? AND status!='confirmed'", [job.id.sql]).first!.int("n")
        if missing == 0 {
            try db.execute("UPDATE jobs SET state='confirmed',failure=NULL,retry_at=NULL,last_confirmed=? WHERE id=?", [Date().sql, job.id.sql])
            try db.execute("UPDATE attempts SET ended=? WHERE job_id=? AND cycle=? AND number=? AND ended IS NULL", [Date().sql, job.id.sql, job.cycleID.sql, .integer(Int64(job.attempts))])
        }
        try record(.confirmation, context: context(job, runID: runID, resource: resource.id), decision: .confirmed, from: job.state, to: missing == 0 ? .confirmed : job.state)
    }
    func storeFailure(_ error: SafeFailure, job: JobRecord) throws {
        try db.execute("INSERT INTO failures(job_id,cycle,attempt,occurred,body) VALUES(?,?,?,?,?)", [job.id.sql, job.cycleID.sql, .integer(Int64(job.attempts)), Date().sql, try db.encode(error)])
    }
    public func failAttempt(jobID: UUID, failure requested: UploadFailure, runID: UUID? = nil, now: Date = Date(), resourceID: UUID? = nil, transferID: UUID? = nil) throws {
        try transaction {
            let job = try loadJob(jobID)
            guard job.state != .confirmed else { return }
            // A native result can settle while the worker returns its earlier
            // uncertain outcome. Resolve that race inside this SQLite transaction.
            var failure = requested
            if let resourceID, let transferID,
               let resource = job.plan.resources.first(where: { $0.id == resourceID }),
               let checkpoint = try providerCheckpoint(destinationID: job.destination.id, tag: resource.tag),
               checkpoint.transferID == transferID, checkpoint.inputsTerminal, checkpoint.phase == .rejected,
               let settled = checkpoint.failure { failure = settled }
            let suspended = !failure.didStartTransfer && failure.acceptance == .definitelyNotAccepted
                && (failure.disposition == .waiting || failure.disposition == .providerWait)
            try storeFailure(failure.error, job: job)
            let state: JobState
            let decision: EventDecision
            var retry: Date? = nil
            if suspended { state = .waiting; decision = .wait }
            else if failure.acceptance == .unknown { state = .reconciling; decision = .reconcile }
            else if failure.disposition == .permanent || job.attempts >= 3 { state = .failed; decision = .skip }
            else if failure.disposition == .providerWait || failure.disposition == .waiting { state = .waiting; decision = .wait }
            else { state = .delayed; decision = .retry }
            if state == .delayed || state == .reconciling {
                let transient = failure.error.category == .connectivity || failure.error.category == .timeout
                let delay = transient ? (job.attempts <= 1 ? 30.0 : 120.0) : (job.attempts <= 1 ? 5.0 : 20.0)
                let jittered = now.addingTimeInterval(delay * Double.random(in: 0.8...1.2))
                retry = max(jittered, failure.retryAfter ?? jittered)
            } else if state == .waiting, failure.disposition != .providerWait {
                retry = waitingDeadline(failure.error, now: now)
                if let deadline = failure.retryAfter { retry = max(retry ?? deadline, deadline) }
            }
            try db.execute("UPDATE jobs SET state=?,failure=?,retry_at=? WHERE id=?", [.text(state.rawValue), try db.encode(failure.error), retry?.sql ?? .null, jobID.sql])
            if state != .failed && failure.disposition != .providerWait { try moveToQueueEnd(jobID) }
            try db.execute("UPDATE attempts SET ended=?,suspended=?,failure=? WHERE job_id=? AND cycle=? AND number=? AND ended IS NULL", [suspended ? .null : now.sql, .integer(suspended ? 1 : 0), try db.encode(failure.error), jobID.sql, job.cycleID.sql, .integer(Int64(job.attempts))])
            if failure.disposition == .providerWait {
                try db.execute("UPDATE destinations SET blocked=?,resume_at=? WHERE id=?", [try db.encode(failure.error), failure.retryAfter?.sql ?? .null, job.destination.id.sql])
            }
            try record(state == .failed ? .exhausted : .failure, context: context(job, runID: runID), severity: .error, decision: decision, from: job.state, to: state, failure: failure.error)
            if retry != nil { try record(.retryScheduled, context: context(job, runID: runID), decision: decision) }
        }
    }
    /// Preparation/network waits before transport do not consume the attempt budget.
    public func deferPreparation(jobID: UUID, failure: SafeFailure, permanent: Bool, runID: UUID) throws {
        let job = try loadJob(jobID)
        guard job.state != .confirmed else { return }
        try transaction {
            try storeFailure(failure, job: job)
            if !permanent { try moveToQueueEnd(jobID) }
            let retry = permanent ? nil : waitingDeadline(failure)
            try db.execute("UPDATE jobs SET state=?,failure=?,retry_at=? WHERE id=?", [.text(permanent ? "failed" : "waiting"), try db.encode(failure), retry?.sql ?? .null, jobID.sql])
            try record(.preparation, context: context(job, runID: runID), severity: .warning, decision: permanent ? .skip : .wait, from: job.state, to: permanent ? .failed : .waiting, failure: failure)
            if retry != nil { try record(.retryScheduled, context: context(job, runID: runID), decision: .reconcile) }
        }
    }
    /// System/network/source state changed. Unchanged exhausted jobs stay exhausted.
    public func wakeWaiting(destinationID: UUID) throws {
        try db.execute("UPDATE jobs SET state='reconciling',retry_at=NULL WHERE destination_id=? AND state='waiting' AND COALESCE(json_extract(CAST(failure AS TEXT),'$.cause'),'')!='pairingUnverified'", [destinationID.sql])
    }
    /// Only an explicit user Retry creates a new three-attempt cycle. All previous
    /// attempts/failures/receipts survive. Active/uncertain transports cannot reset.
    public func explicitRetry(jobID: UUID, runID: UUID? = nil) throws {
        try transaction {
            let job = try loadJob(jobID)
            guard [.failed, .waiting, .reconciling, .delayed].contains(job.state),
                  try db.rows("SELECT COUNT(*) AS n FROM transfers WHERE job_id=?", [jobID.sql]).first!.int("n") == 0 else { throw CoreError.invalidTransition }
            try db.execute("UPDATE jobs SET cycle=?,attempts=0,state='reconciling',retry_at=NULL WHERE id=?", [UUID().sql, jobID.sql])
            try db.execute("UPDATE obligations SET status='unknown' WHERE job_id=? AND status!='confirmed'", [jobID.sql])
            try record(.explicitRetry, context: context(try loadJob(jobID), runID: runID), decision: .reconcile)
        }
    }
    public func nextWake(destinationID: UUID) throws -> Date? {
        let now = Date()
        guard let destination = try db.rows("SELECT * FROM destinations WHERE id=? AND selected=1 AND enabled=1", [destinationID.sql]).first else { return nil }
        if case .blob = destination.values["blocked"] {
            return destination.double("resume_at").map(Date.init(timeIntervalSince1970:)).flatMap { $0 > now ? $0 : nil }
        }
        guard destination.int("recovered") == 1 else { return nil }
        let row = try db.rows("""
            SELECT MIN(j.retry_at) AS wake FROM jobs j WHERE j.destination_id=?
            AND j.state IN ('delayed','reconciling','waiting') AND j.retry_at>?
            AND NOT EXISTS(SELECT 1 FROM transfers t WHERE t.job_id=j.id)
            AND EXISTS(SELECT 1 FROM aliases x JOIN assets a ON a.id=x.asset_id JOIN scans s ON s.id=a.scan_id
                WHERE x.job_id=j.id AND s.complete=1 AND a.scan_id=(SELECT value FROM meta WHERE key='scan'))
            """, [destinationID.sql, now.sql]).first
        return row?.double("wake").map(Date.init(timeIntervalSince1970:))
    }
    /// Local/transient conditions get one persisted recheck deadline, consumed by
    /// the existing scheduler. User-action/account waits have no polling timer.
    private func inspectionDeadline(_ failure: SafeFailure, job: JobRecord) throws -> Date? {
        guard failure.cause == .pairingUnverified else { return waitingDeadline(failure) }
        // Allow index/pairing propagation, then require a deliberate fallback or
        // explicit retry. Generic provider wakes cannot bypass these deadlines.
        let count = try db.rows("SELECT COUNT(*) AS n FROM failures WHERE job_id=? AND cycle=? AND json_extract(CAST(body AS TEXT),'$.cause')='pairingUnverified'", [job.id.sql, job.cycleID.sql]).first!.int("n")
        if count == 1 { return Date().addingTimeInterval(60) }
        if count == 2 { return Date().addingTimeInterval(300) }
        return nil
    }
    private func waitingDeadline(_ failure: SafeFailure, now: Date = Date()) -> Date? {
        // A persistent pairing mismatch needs an explicit fallback choice. Keep
        // accepted components and avoid polling the same incompatible pair.
        if failure.cause == .pairingUnverified { return nil }
        switch failure.category {
        case .diskFull: return now.addingTimeInterval(60)
        case .connectivity, .timeout, .transfer, .finalization, .reconciliation:
            return now.addingTimeInterval(30)
        case .authentication, .accessDenied, .quota, .rateLimit, .sourceUnavailable,
             .unsupportedOriginal, .invariant: return nil
        }
    }
}
