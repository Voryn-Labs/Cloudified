import Foundation

/// The only owner of SQLite. Receipt/attempt/critical event writes share one commit.
/// If a commit fails, callers stop that lane and retain transport ownership; never
/// announce Saved or substitute an in-memory success flag.
public actor Ledger {
    let db: SQLite
    let version: String
    let revision: String
    private var observers: [UUID: AsyncStream<Void>.Continuation] = [:]
    // Four origins, not an entry for every historical asset. Disposable samples
    // must not cause a durable write for each UI progress update.
    var progressSamples: [String: (at: TimeInterval, resource: UUID?, bytes: Int64)] = [:]
    var cachedSnapshot: (revision: UInt64, value: LedgerSnapshot)?
    var computedSnapshots: UInt64 = 0
    var reusedSnapshots: UInt64 = 0
    public init(databaseURL: URL, version: String, revision: String) throws {
        guard !version.isEmpty, version.utf8.count <= 64, revision.utf8.count <= 64,
              (revision == "unknown" || revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })) else { throw CoreError.invalidContract }
        self.version = version; self.revision = revision
        let connection = try SQLite(url: databaseURL)
        try Schema.install(connection)
        try connection.execute("CREATE INDEX IF NOT EXISTS diagnostic_priority ON events(critical,seq)")
        try connection.execute("CREATE INDEX IF NOT EXISTS diagnostic_failure_job ON failures(job_id,seq)")
        try connection.execute("CREATE INDEX IF NOT EXISTS transfers_job ON transfers(job_id)")
        // Runtime ownership must be reconciled on EVERY process start, even if a
        // previous history scan completed. Neither persisted lease counts nor a
        // previously absent remote lookup establish post-crash absence.
        try connection.transaction {
            try connection.execute("UPDATE destinations SET recovered=0")
            try connection.execute("UPDATE obligations SET status='unknown' WHERE status!='confirmed'")
            try connection.execute("UPDATE jobs SET state='reconciling' WHERE state IN ('uploading','preparing','ready','checking')")
            try connection.execute("DELETE FROM reservations")
        }
        db = connection
    }
    /// Bounded invalidation stream for real UI snapshots. It carries no invented
    /// counts and is NOT an automatic backup trigger. P5 commands/producer events
    /// explicitly request drains; progress events cannot start an empty-batch loop.
    public func observeChanges() throws -> AsyncStream<Void> {
        guard observers.count < 4 else { throw CoreError.invalidContract }
        let id = UUID()
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        observers[id] = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        return pair.stream
    }
    private func removeObserver(_ id: UUID) { observers.removeValue(forKey: id) }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let result = try db.transaction(body)
        for observer in observers.values { observer.yield(()) }
        return result
    }

    public func selectDestination(_ requested: Destination) throws -> Destination {
        guard UploadPlan.hex(requested.verifiedFingerprint, length: 64) else { throw CoreError.invalidContract }
        return try transaction {
            let rows = try db.rows("SELECT body FROM destinations WHERE provider=? AND fingerprint=?", [.text(requested.provider.rawValue), .text(requested.verifiedFingerprint)])
            let destination = try rows.first.map { try db.decode(Destination.self, $0, "body") } ?? requested
            try db.execute("UPDATE destinations SET selected=0 WHERE provider=?", [.text(destination.provider.rawValue)])
            try db.execute("INSERT INTO destinations(id,provider,fingerprint,body,selected) VALUES(?,?,?,?,1) ON CONFLICT(id) DO UPDATE SET selected=1,recovered=0", [destination.id.sql, .text(destination.provider.rawValue), .text(destination.verifiedFingerprint), try db.encode(destination)])
            try record(.mappingChanged, context: EventContext(origin: destination.provider.origin, destinationID: destination.id), decision: .reconcile)
            return destination
        }
    }
    /// P5 settings first disables and settles the provider. Replanning a changed
    /// Live Photo policy must not keep counting an old, smaller coverage as Saved.
    /// Jobs, receipts and attempt history survive; only current scan bindings reset.
    public func invalidateCurrentCoverage(destinationID: UUID) throws {
        try transaction {
            guard let row = try db.rows("SELECT enabled,selected FROM destinations WHERE id=?", [destinationID.sql]).first,
                  row.int("enabled") == 0, row.int("selected") == 1,
                  try db.rows("SELECT id FROM transfers WHERE destination_id=? LIMIT 1", [destinationID.sql]).isEmpty else { throw CoreError.invalidTransition }
            try db.execute("DELETE FROM aliases WHERE destination_id=? AND asset_id IN (SELECT id FROM assets WHERE scan_id=(SELECT value FROM meta WHERE key='scan'))", [destinationID.sql])
            try db.execute("DELETE FROM source_failures WHERE destination_id=? AND asset_id IN (SELECT id FROM assets WHERE scan_id=(SELECT value FROM meta WHERE key='scan'))", [destinationID.sql])
            try record(.mappingChanged, context: EventContext(destinationID: destinationID), decision: .reconcile)
        }
    }
    public func selectedDestination(_ provider: Provider) throws -> Destination? {
        try db.rows("SELECT body FROM destinations WHERE provider=? AND selected=1", [.text(provider.rawValue)]).first.map { try db.decode(Destination.self, $0, "body") }
    }
    public func setEnabled(_ id: UUID, _ enabled: Bool) throws {
        try transaction {
            try db.execute("UPDATE destinations SET enabled=? WHERE id=?", [.integer(enabled ? 1 : 0), id.sql])
            try record(.enabledChanged, context: EventContext(destinationID: id), decision: enabled ? .reconcile : .wait)
        }
    }
    public func deselectDestination(_ id: UUID) throws {
        try transaction {
            try db.execute("UPDATE destinations SET selected=0,enabled=0 WHERE id=?", [id.sql])
            try record(.mappingChanged, context: EventContext(destinationID: id), decision: .wait)
        }
    }
    /// Provider recovery verifies account scope and live OS/TDLib readers. Resource
    /// inspection must separately establish fresh presence/absence before sending.
    /// Marking the destination ready cannot clear holds or authorize a resend.
    public func completeDestinationRecovery(_ id: UUID, inventoriedLiveTransfers: Set<UUID> = [],
                                            protectedUnresolvedTransfers: Set<UUID> = []) throws {
        try transaction {
            let holds = try db.rows("SELECT COUNT(*) AS n FROM transfers WHERE destination_id=?", [id.sql]).first!.int("n")
            let retained = Set(try retainedTransferIDs(destinationID: id))
            // A missing native message is not terminal-reader or absence proof.
            // Explicitly protected Telegram inputs may stay quarantined while
            // unrelated jobs run. They retain their holds and cannot be claimed.
            for transferID in protectedUnresolvedTransfers {
                guard let row = try db.rows("""
                    SELECT t.job_id,t.resource_id FROM transfers t WHERE t.id=? AND t.destination_id=?
                    AND EXISTS(SELECT 1 FROM holds h JOIN staged s ON s.id=h.file_id
                        WHERE h.transfer_id=t.id AND h.job_id=t.job_id
                        AND h.destination_id=t.destination_id AND s.deleting=0)
                    """, [transferID.sql, id.sql]).first,
                      let jobID = UUID(uuidString: try row.string("job_id")),
                      let resourceID = UUID(uuidString: try row.string("resource_id")) else { throw CoreError.recoveryRequired }
                let job = try loadJob(jobID)
                guard job.destination.provider == .telegram,
                      let resource = job.plan.resources.first(where: { $0.id == resourceID }),
                      let checkpoint = try providerCheckpoint(destinationID: id, tag: resource.tag),
                      checkpoint.transferID == transferID, checkpoint.jobID == jobID,
                      checkpoint.phase == .uncertain, !checkpoint.inputsTerminal else { throw CoreError.recoveryRequired }
            }
            let protected = inventoriedLiveTransfers.union(protectedUnresolvedTransfers)
            guard protected.count <= 8, holds == 0 || retained.isSubset(of: protected) else { throw CoreError.recoveryRequired }
            try db.execute("UPDATE destinations SET recovered=1 WHERE id=? AND recovered!=1", [id.sql])
            if db.changes > 0 { try record(.recovery, context: EventContext(destinationID: id), decision: .proceed) }
        }
    }
    /// A provider-wide recovery rejection fences this selected mapping, not its files.
    public func blockDestination(_ id: UUID, failure: SafeFailure, resumeAt: Date?) throws {
        guard [.authentication, .accessDenied, .quota, .rateLimit].contains(failure.category) else { throw CoreError.invalidContract }
        try transaction {
            guard try db.rows("SELECT id FROM destinations WHERE id=? AND selected=1", [id.sql]).count == 1 else { throw CoreError.staleMapping }
            try db.execute("UPDATE destinations SET blocked=?,resume_at=?,recovered=0 WHERE id=?", [try db.encode(failure), resumeAt?.sql ?? .null, id.sql])
            try record(.recovery, context: EventContext(destinationID: id), severity: .error, decision: .wait, failure: failure)
        }
    }
    public func unblockDestination(_ id: UUID) throws {
        try transaction {
            try db.execute("UPDATE destinations SET blocked=NULL,resume_at=NULL WHERE id=? AND (blocked IS NOT NULL OR resume_at IS NOT NULL)", [id.sql])
            let unblocked = db.changes > 0
            try wakeWaiting(destinationID: id)
            if unblocked || db.changes > 0 { try record(.resume, context: EventContext(destinationID: id), decision: .reconcile) }
        }
    }
    public func beginScan() throws -> UUID {
        let id = UUID()
        try transaction {
            try db.execute("INSERT INTO scans(id,created) VALUES(?,?)", [id.sql, Date().sql])
            try db.execute("INSERT INTO meta(key,value) VALUES('scan',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [id.sql])
            try record(.scanStart, decision: .proceed)
        }
        return id
    }
    /// P3 enumerates PhotoKit in bounded pages. Return canonical IDs so rescans
    /// do not manufacture new local asset identities. No media bytes are retained.
    public func registerAssets(_ assets: [AssetIdentity], scanID: UUID) throws -> [AssetIdentity] {
        guard assets.count <= 200 else { throw CoreError.invalidContract }
        return try transaction {
            guard try db.rows("SELECT id FROM scans WHERE id=? AND complete=0", [scanID.sql]).count == 1 else { throw CoreError.invalidTransition }
            var canonical: [AssetIdentity] = []
            for asset in assets {
                guard UploadPlan.hex(asset.generation, length: 64), !asset.localIdentifier.isEmpty,
                      !asset.localIdentifier.contains("\0"), asset.localIdentifier.utf8.count <= 512 else { throw CoreError.invalidContract }
                if let row = try db.rows("SELECT body FROM assets WHERE local_id=? AND generation=?", [.text(asset.localIdentifier), .text(asset.generation)]).first {
                    let existing = try db.decode(AssetIdentity.self, row, "body")
                    guard existing.kind == asset.kind else { throw CoreError.invalidContract }
                    canonical.append(existing)
                    try db.execute("UPDATE assets SET scan_id=? WHERE id=?", [scanID.sql, existing.id.sql])
                } else {
                    try db.execute("INSERT INTO assets(id,local_id,generation,kind,body,scan_id) VALUES(?,?,?,?,?,?)", [asset.id.sql, .text(asset.localIdentifier), .text(asset.generation), .text(asset.kind.rawValue), try db.encode(asset), scanID.sql])
                    canonical.append(asset)
                }
            }
            try record(.scanPage, decision: .proceed, critical: false)
            return canonical
        }
    }
    /// Incremental rescan from PhotoKit persistent changes. The new scan starts
    /// with every asset of the complete current scan except `localIDs` (inserted,
    /// updated or deleted since it); the caller registers their current versions
    /// and completes the scan. An interrupted scan stays incomplete, so the next
    /// drain falls back to a full scan.
    public func beginIncrementalScan(from previous: UUID, dropping localIDs: [String]) throws -> (id: UUID, carried: Int) {
        guard localIDs.count <= 100_000 else { throw CoreError.invalidContract }
        let id = UUID()
        let carried = try transaction { () throws -> Int in
            guard try db.rows("SELECT s.id FROM scans s JOIN meta m ON m.key='scan' AND m.value=s.id WHERE s.id=? AND s.complete=1", [previous.sql]).count == 1 else { throw CoreError.invalidTransition }
            try db.execute("INSERT INTO scans(id,created) VALUES(?,?)", [id.sql, Date().sql])
            try db.execute("UPDATE meta SET value=? WHERE key='scan'", [id.sql])
            try db.execute("UPDATE assets SET scan_id=? WHERE scan_id=?", [id.sql, previous.sql])
            var start = 0
            while start < localIDs.count {
                let page = localIDs[start..<min(start + 500, localIDs.count)]
                let marks = Array(repeating: "?", count: page.count).joined(separator: ",")
                try db.execute("UPDATE assets SET scan_id=? WHERE scan_id=? AND local_id IN (\(marks))",
                               [previous.sql, id.sql] + page.map { SQLValue.text($0) })
                start += page.count
            }
            try record(.scanStart, decision: .proceed)
            return Int(try db.rows("SELECT COUNT(*) AS n FROM assets WHERE scan_id=?", [id.sql]).first!.int("n"))
        }
        return (id, carried)
    }
    public func completeScan(_ id: UUID) throws {
        try transaction {
            try db.execute("UPDATE scans SET complete=1 WHERE id=?", [id.sql])
            guard db.changes == 1 else { throw CoreError.invalidTransition }
            try record(.scanComplete, decision: .proceed)
        }
    }
    /// Private, bounded source-v1 JSON recipe: PhotoKit resource descriptors,
    /// measured original hashes, metadata and lossless split recipe. No media
    /// bytes/credentials. P3 owns its Codable schema; diagnostics never export it.
    public func saveSourceRecipe(assetID: UUID, json: Data) throws {
        guard !json.isEmpty, json.count <= 262_144,
              (try? JSONSerialization.jsonObject(with: json)) != nil else { throw CoreError.invalidContract }
        if try sourceRecipe(assetID: assetID) == json { return }
        try transaction {
            try db.execute("INSERT INTO source_recipes(asset_id,body) VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET body=excluded.body", [assetID.sql, .blob(json)])
        }
    }
    public func sourceRecipe(assetID: UUID) throws -> Data? {
        try db.rows("SELECT body FROM source_recipes WHERE asset_id=?", [assetID.sql]).first.map { try $0.data("body") }
    }
    /// A matching alias proves planning already happened, not remote delivery.
    /// Failed/uncertain jobs retain their state; the engine still reconciles them.
    public func hasEnqueuedPlan(assetID: UUID, destinationID: UUID, coverageHash: String) throws -> Bool {
        guard UploadPlan.hex(coverageHash, length: 64) else { throw CoreError.invalidContract }
        return try !db.rows("""
            SELECT 1 FROM aliases x JOIN jobs j ON j.id=x.job_id
            WHERE x.asset_id=? AND x.destination_id=? AND j.coverage=?
              AND NOT EXISTS(SELECT 1 FROM source_failures f WHERE f.asset_id=x.asset_id AND f.destination_id=x.destination_id)
            LIMIT 1
            """, [assetID.sql, destinationID.sql, .text(coverageHash)]).isEmpty
    }
    @discardableResult public func enqueue(assetID: UUID, destinationID: UUID, plan: UploadPlan) throws -> UUID {
        try plan.validate()
        return try transaction {
            let existing = try db.rows("SELECT id,plan FROM jobs WHERE destination_id=? AND coverage=?", [destinationID.sql, .text(plan.coverageHash)]).first
            let id: UUID
            if let existing {
                guard let storedID = UUID(uuidString: try existing.string("id")) else { throw CoreError.invalidContract }
                let stored = try db.decode(UploadPlan.self, existing, "plan")
                // Resource UUIDs can differ after reinstall/rescan; deterministic
                // tags, ordering, originals and frozen policy must still agree.
                guard stored.policyVersion == plan.policyVersion,
                      stored.resources.map(\.tag) == plan.resources.map(\.tag),
                      stored.resources.map(\.originals) == plan.resources.map(\.originals),
                      stored.resources.map(\.role) == plan.resources.map(\.role) else { throw CoreError.invalidContract }
                id = storedID
            } else {
                id = UUID()
                try db.execute("INSERT INTO jobs(id,destination_id,asset_id,coverage,plan,state,cycle) VALUES(?,?,?,?,?,'checking',?)", [id.sql, destinationID.sql, assetID.sql, .text(plan.coverageHash), try db.encode(plan), UUID().sql])
                for resource in plan.resources {
                    try db.execute("INSERT INTO obligations(job_id,resource_id,tag) VALUES(?,?,?)", [id.sql, resource.id.sql, .text(resource.tag)])
                }
            }
            try db.execute("INSERT INTO aliases(job_id,asset_id,destination_id) VALUES(?,?,?) ON CONFLICT(asset_id,destination_id) DO UPDATE SET job_id=excluded.job_id WHERE aliases.job_id!=excluded.job_id", [id.sql, assetID.sql, destinationID.sql])
            try db.execute("DELETE FROM source_failures WHERE asset_id=? AND destination_id=?", [assetID.sql, destinationID.sql])
            // Deliberately do not reset failed/exhausted/unknown jobs on a rescan.
            return id
        }
    }
    func loadJob(_ id: UUID) throws -> JobRecord {
        guard let row = try db.rows("SELECT j.*,d.body AS destination_body,a.body AS asset_body FROM jobs j JOIN destinations d ON d.id=j.destination_id JOIN assets a ON a.id=COALESCE((SELECT x.asset_id FROM aliases x JOIN assets ax ON ax.id=x.asset_id WHERE x.job_id=j.id ORDER BY (ax.scan_id=(SELECT value FROM meta WHERE key='scan')) DESC,x.asset_id LIMIT 1),j.asset_id) WHERE j.id=?", [id.sql]).first,
              let cycle = UUID(uuidString: try row.string("cycle")), let state = JobState(rawValue: try row.string("state")) else { throw CoreError.invalidContract }
        return JobRecord(id: id, destination: try db.decode(Destination.self, row, "destination_body"), asset: try db.decode(AssetIdentity.self, row, "asset_body"), plan: try db.decode(UploadPlan.self, row, "plan"), state: state, cycleID: cycle, attempts: Int(row.int("attempts")), retryAt: row.double("retry_at").map(Date.init(timeIntervalSince1970:)))
    }
    public func job(_ id: UUID) throws -> JobRecord { try loadJob(id) }
    func context(_ job: JobRecord, runID: UUID? = nil, resource: UUID? = nil) -> EventContext {
        EventContext(runID: runID, origin: job.destination.provider.origin, destinationID: job.destination.id,
                     jobID: job.id, assetID: job.asset.id, resourceID: resource, cycleID: job.cycleID, attempt: job.attempts)
    }
    public func receipts(for jobID: UUID) throws -> [RemoteReceipt] {
        try db.rows("SELECT r.body FROM receipts r JOIN jobs j ON j.destination_id=r.destination_id JOIN obligations o ON o.job_id=j.id AND o.tag=r.tag WHERE j.id=?", [jobID.sql]).map { try db.decode(RemoteReceipt.self, $0, "body") }
    }
    public func missingResources(for jobID: UUID) throws -> [ResourceRequirement] {
        let job = try loadJob(jobID)
        let tags = try Set(db.rows("SELECT tag FROM obligations WHERE job_id=? AND status!='confirmed'", [jobID.sql]).map { try $0.string("tag") })
        return job.plan.resources.filter { tags.contains($0.tag) }
    }
}
