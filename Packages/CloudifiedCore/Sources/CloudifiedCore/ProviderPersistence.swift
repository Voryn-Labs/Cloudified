import Foundation

/// Private provider recovery evidence. These payloads may contain remote IDs and
/// resumable URLs: never export them through Diagnostics or presentation models.
public enum ProviderCheckpointPhase: String, Codable, Sendable {
    case prepared, transferring, committing, confirmed, rejected, uncertain
    /// Google only: accepted components are preserved; remaining components have
    /// no uncertain commit/reader. A new transfer must resume this exact payload.
    case partial
}
public struct ProviderCheckpoint: Codable, Sendable {
    public let destinationID: UUID
    public let tag: String
    public let transferID: UUID
    public let jobID: UUID
    public let phase: ProviderCheckpointPhase
    public let inputsTerminal: Bool
    public let payload: Data
    public let failure: UploadFailure?
    public init(destinationID: UUID, tag: String, transferID: UUID, jobID: UUID,
                phase: ProviderCheckpointPhase, inputsTerminal: Bool, payload: Data, failure: UploadFailure? = nil) {
        self.destinationID = destinationID; self.tag = tag; self.transferID = transferID
        self.jobID = jobID; self.phase = phase; self.inputsTerminal = inputsTerminal; self.payload = payload; self.failure = failure
    }
}
public struct RetainedTransfer: Sendable {
    public let id: UUID
    public let job: JobRecord
    public let resource: ResourceRequirement
}
public struct RemoteIndexEntry: Sendable {
    public let tag: String
    public let reference: Data
    public init(tag: String, reference: Data) { self.tag = tag; self.reference = reference }
}
extension Ledger {
    /// Conservative additional native/OS copy promise, independent of staging's
    /// single-oversized-file rule. It survives a crash until transport inventory.
    public func reserveTransport(_ id: UUID, bytes: Int64, availableBytes: Int64) throws {
        guard bytes >= 0, availableBytes >= 0 else { throw CoreError.invalidContract }
        try transaction {
            let promised = try db.rows("SELECT (SELECT COALESCE(SUM(bytes),0) FROM reservations) + (SELECT COALESCE(SUM(bytes),0) FROM transport_reservations WHERE id!=?) AS n", [id.sql]).first!.int("n")
            let safety: Int64 = 536_870_912
            guard availableBytes >= safety, promised <= availableBytes - safety,
                  bytes <= availableBytes - safety - promised else { throw SafeFailure(.diskFull, domain: .fileSystem, cause: .insufficientSpace) }
            try db.execute("INSERT INTO transport_reservations(id,bytes) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET bytes=excluded.bytes", [id.sql, .integer(bytes)])
        }
    }

    public func bindProviderProfile(destination: Destination, profileID: String, scope: Data) throws {
        guard !profileID.isEmpty, profileID.utf8.count <= 64,
              profileID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }),
              !scope.isEmpty, scope.count <= 4096 else { throw CoreError.invalidContract }
        try transaction {
            guard let row = try db.rows("SELECT fingerprint,provider FROM destinations WHERE id=?", [destination.id.sql]).first,
                  try row.string("fingerprint") == destination.verifiedFingerprint,
                  try row.string("provider") == destination.provider.rawValue else { throw CoreError.staleMapping }
            if let old = try db.rows("SELECT profile,scope FROM provider_bindings WHERE destination_id=?", [destination.id.sql]).first {
                guard try old.data("scope") == scope else { throw CoreError.staleMapping }
                if try old.string("profile") != profileID {
                    guard try retainedTransferIDs(destinationID: destination.id).isEmpty else { throw CoreError.recoveryRequired }
                }
            }
            try db.execute("INSERT INTO provider_bindings(destination_id,profile,scope) VALUES(?,?,?) ON CONFLICT(destination_id) DO UPDATE SET profile=excluded.profile", [destination.id.sql, .text(profileID), .blob(scope)])
            try record(.mappingChanged, context: EventContext(origin: destination.provider.origin, destinationID: destination.id), decision: .reconcile)
        }
    }
    public func providerBinding(destinationID: UUID) throws -> (profileID: String, scope: Data)? {
        guard let row = try db.rows("SELECT profile,scope FROM provider_bindings WHERE destination_id=?", [destinationID.sql]).first else { return nil }
        return (try row.string("profile"), try row.data("scope"))
    }
    public func saveProviderCheckpoint(_ checkpoint: ProviderCheckpoint) throws {
        guard UploadPlan.hex(checkpoint.tag, length: 64), checkpoint.payload.count <= 262_144 else { throw CoreError.invalidContract }
        try transaction {
            let job = try loadJob(checkpoint.jobID)
            guard job.destination.id == checkpoint.destinationID,
                  let resource = job.plan.resources.first(where: { $0.tag == checkpoint.tag }) else { throw CoreError.staleMapping }
            if let old = try providerCheckpoint(destinationID: checkpoint.destinationID, tag: checkpoint.tag), old.transferID != checkpoint.transferID {
                // Never overwrite evidence for a possibly accepted earlier send.
                guard old.inputsTerminal, old.phase == .rejected ||
                    (job.destination.provider == .google && old.phase == .partial) else { throw CoreError.recoveryRequired }
            }
            try db.execute("INSERT INTO provider_checkpoints(destination_id,tag,transfer_id,body) VALUES(?,?,?,?) ON CONFLICT(destination_id,tag) DO UPDATE SET transfer_id=excluded.transfer_id,body=excluded.body", [checkpoint.destinationID.sql, .text(checkpoint.tag), checkpoint.transferID.sql, try db.encode(checkpoint)])
            try record(checkpoint.phase == .committing ? .finalization : .recovery,
                       context: EventContext(origin: job.destination.provider.origin, destinationID: job.destination.id, jobID: job.id, resourceID: resource.id, cycleID: job.cycleID, attempt: job.attempts),
                       decision: checkpoint.phase == .confirmed ? .confirmed : .reconcile)
        }
    }
    public func providerCheckpoint(destinationID: UUID, tag: String) throws -> ProviderCheckpoint? {
        try db.rows("SELECT body FROM provider_checkpoints WHERE destination_id=? AND tag=?", [destinationID.sql, .text(tag)]).first.map { try db.decode(ProviderCheckpoint.self, $0, "body") }
    }
    /// A late native confirmation/rejection can arrive during history lookup.
    /// Never regress terminal evidence when quarantining an unmatched send.
    public func quarantineTelegramTransfer(_ checkpoint: ProviderCheckpoint) throws -> Bool {
        guard checkpoint.phase == .uncertain, !checkpoint.inputsTerminal,
              UploadPlan.hex(checkpoint.tag, length: 64), checkpoint.payload.count <= 262_144 else { throw CoreError.invalidContract }
        return try transaction {
            let job = try loadJob(checkpoint.jobID)
            guard job.destination.provider == .telegram, job.destination.id == checkpoint.destinationID,
                  let resource = job.plan.resources.first(where: { $0.tag == checkpoint.tag }),
                  let current = try providerCheckpoint(destinationID: checkpoint.destinationID, tag: checkpoint.tag),
                  current.transferID == checkpoint.transferID, current.jobID == checkpoint.jobID else { throw CoreError.recoveryRequired }
            guard !current.inputsTerminal, current.phase == .transferring || current.phase == .uncertain else { return false }
            guard try !db.rows("""
                SELECT t.id FROM transfers t WHERE t.id=? AND t.job_id=? AND t.resource_id=?
                AND EXISTS(SELECT 1 FROM holds h JOIN staged s ON s.id=h.file_id
                    WHERE h.transfer_id=t.id AND h.job_id=t.job_id
                    AND h.destination_id=t.destination_id AND s.deleting=0)
                """, [checkpoint.transferID.sql, job.id.sql, resource.id.sql]).isEmpty else { return false }
            try db.execute("UPDATE provider_checkpoints SET body=? WHERE destination_id=? AND tag=? AND transfer_id=?", [try db.encode(checkpoint), checkpoint.destinationID.sql, .text(checkpoint.tag), checkpoint.transferID.sql])
            try record(.recovery, context: EventContext(origin: .telegram, destinationID: job.destination.id,
                jobID: job.id, resourceID: resource.id, cycleID: job.cycleID, attempt: job.attempts), decision: .reconcile)
            return true
        }
    }
    /// A confirmed Telegram reference failed direct validation, then a fresh full
    /// census found no tag. Supersede only the exact inspected checkpoint, with
    /// no retained reader. Never erase a live/uncertain send or historical receipt.
    public func supersedeStaleTelegramCheckpoint(_ expected: ProviderCheckpoint, epoch: UUID) throws -> Bool {
        try transaction {
            guard expected.phase == .confirmed, expected.inputsTerminal,
                  let current = try providerCheckpoint(destinationID: expected.destinationID, tag: expected.tag),
                  current.phase == .confirmed, current.inputsTerminal,
                  current.transferID == expected.transferID, current.jobID == expected.jobID,
                  current.payload == expected.payload else { return false }
            let job = try loadJob(current.jobID)
            guard job.destination.provider == .telegram,
                  try !hasRetainedTransfers(jobID: current.jobID) else { return false }
            let lookup = try remoteIndex(destinationID: expected.destinationID, epoch: epoch, tag: expected.tag)
            guard lookup.complete, lookup.reference == nil else { return false }
            let replacement = ProviderCheckpoint(destinationID: current.destinationID, tag: current.tag,
                transferID: current.transferID, jobID: current.jobID, phase: .rejected,
                inputsTerminal: true, payload: current.payload)
            try db.execute("UPDATE provider_checkpoints SET body=? WHERE destination_id=? AND tag=?", [try db.encode(replacement), current.destinationID.sql, .text(current.tag)])
            try record(.recovery, context: EventContext(origin: .telegram, destinationID: current.destinationID,
                jobID: current.jobID), decision: .reconcile)
            return true
        }
    }
    public func retainedTransfers(destinationID: UUID, afterID: UUID? = nil, limit: Int = 100) throws -> [RetainedTransfer] {
        guard (1...100).contains(limit) else { throw CoreError.invalidContract }
        return try db.rows("SELECT id,job_id,resource_id FROM transfers WHERE destination_id=? AND id>? ORDER BY id LIMIT ?", [destinationID.sql, .text(afterID?.uuidString ?? ""), .integer(Int64(limit))]).map { row in
            guard let id = UUID(uuidString: try row.string("id")), let jobID = UUID(uuidString: try row.string("job_id")),
                  let resourceID = UUID(uuidString: try row.string("resource_id")) else { throw CoreError.invalidContract }
            let job = try loadJob(jobID)
            guard let resource = job.plan.resources.first(where: { $0.id == resourceID }) else { throw CoreError.invalidContract }
            return RetainedTransfer(id: id, job: job, resource: resource)
        }
    }
    /// A new scan invalidates old absence evidence immediately. Index rows are
    /// disk-backed and read a page at a time; old epochs cannot establish absence.
    public func beginRemoteIndex(destinationID: UUID) throws -> UUID {
        let epoch = UUID()
        try transaction {
            try db.execute("INSERT INTO remote_scans(destination_id,epoch,complete) VALUES(?,?,0) ON CONFLICT(destination_id) DO UPDATE SET epoch=excluded.epoch,complete=0", [destinationID.sql, epoch.sql])
            try db.execute("DELETE FROM remote_index WHERE destination_id=?", [destinationID.sql])
        }
        return epoch
    }
    public func addRemoteIndex(destinationID: UUID, epoch: UUID, entries: [RemoteIndexEntry]) throws {
        guard entries.count <= 100 else { throw CoreError.invalidContract }
        try transaction {
            try requireRemoteEpoch(destinationID, epoch)
            for entry in entries {
                guard UploadPlan.hex(entry.tag, length: 64), !entry.reference.isEmpty, entry.reference.count <= 4096 else { throw CoreError.invalidContract }
                try db.execute("INSERT INTO remote_index(destination_id,tag,reference) VALUES(?,?,?) ON CONFLICT(destination_id,tag) DO UPDATE SET reference=excluded.reference", [destinationID.sql, .text(entry.tag), .blob(entry.reference)])
            }
        }
    }
    public func finishRemoteIndex(destinationID: UUID, epoch: UUID) throws {
        try transaction {
            try requireRemoteEpoch(destinationID, epoch)
            try db.execute("UPDATE remote_scans SET complete=1 WHERE destination_id=?", [destinationID.sql])
            try record(.recovery, context: EventContext(destinationID: destinationID), decision: .proceed)
        }
    }
    public func remoteIndex(destinationID: UUID, epoch: UUID, tag: String) throws -> (reference: Data?, complete: Bool) {
        try requireRemoteEpoch(destinationID, epoch)
        let row = try db.rows("SELECT reference FROM remote_index WHERE destination_id=? AND tag=?", [destinationID.sql, .text(tag)]).first
        let complete = try db.rows("SELECT complete FROM remote_scans WHERE destination_id=?", [destinationID.sql]).first!.int("complete") == 1
        return (try row.map { try $0.data("reference") }, complete)
    }
    private func requireRemoteEpoch(_ destination: UUID, _ epoch: UUID) throws {
        guard let row = try db.rows("SELECT epoch FROM remote_scans WHERE destination_id=?", [destination.sql]).first,
              try row.string("epoch") == epoch.uuidString else { throw CoreError.recoveryRequired }
    }
}
