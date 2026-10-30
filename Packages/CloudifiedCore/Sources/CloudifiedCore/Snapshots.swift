import Foundation

public struct MediaCounts: Equatable, Sendable {
    public let total: Int
    public let confirmed: Int
    public let uploaded: Int
    public let alreadyPresent: Int
    public let failed: Int
    public let waiting: Int
    public var excluded: Int = 0
    public var remaining: Int { total - confirmed }
}
public struct ProviderSnapshot: Sendable {
    public let provider: Provider
    public let destinationID: UUID?
    public let enabled: Bool
    public let recoveryComplete: Bool
    public let blockedReason: SafeFailure?
    public let resumeAt: Date?
    public let photos: MediaCounts?
    public let videos: MediaCounts?
    public let lastConfirmedAt: Date?
    public let retainedTransfers: Int
    public let protectedUnresolvedTransfers: Int
    public var excluded: Int? { photos.flatMap { p in videos.map { p.excluded + $0.excluded } } }
    public var total: Int? { photos.flatMap { p in videos.map { p.total + $0.total } } }
    public var confirmed: Int? { photos.flatMap { p in videos.map { p.confirmed + $0.confirmed } } }
    public var remaining: Int? { total.flatMap { t in confirmed.map { t - $0 } } }
}
public struct LedgerSnapshot: Sendable {
    public let scanned: Bool
    public let scanStartedAt: Date?
    public let libraryTotal: Int?
    public let libraryPhotoTotal: Int?
    public let libraryVideoTotal: Int?
    public let savedToBoth: Int?
    public let providers: [ProviderSnapshot]
}
/// Persisted scan identity; the coordinator must never invent an ID on resume.
public struct CurrentLibraryScan: Sendable {
    public let id: UUID
    public let complete: Bool
}
/// Recovery inventory includes deselected mappings with retained readers.
/// UI counters still use selected mappings exclusively.
public struct DestinationInventoryRow: Sendable {
    public let destination: Destination
    public let selected: Bool
    public let enabled: Bool
    public let recoveryComplete: Bool
    public let retainedTransferCount: Int
}
public struct AttemptHistoryRow: Sendable {
    public let cursor: Int64
    public let cycleID: UUID
    public let number: Int
    public let startedAt: Date
    public let endedAt: Date?
    public let suspended: Bool
    public let failure: SafeFailure?
}
public struct FailureRow: Sendable {
    public let recipeData: Data?
    public let retained: Bool
    public let cursor: Int64
    public let job: JobRecord
    public let asset: AssetIdentity
    public let failure: SafeFailure?
    public let confirmedResources: Int
    public let requiredResources: Int
}
public struct ScannedAssetRow: Sendable {
    public let cursor: Int64
    public let asset: AssetIdentity
}
public struct SourceFailureRow: Sendable {
    public let recipeData: Data?
    public let cursor: Int64
    public let asset: AssetIdentity
    public let destination: Destination
    public let error: SafeFailure
    public let permanent: Bool
    public let occurredAt: Date
}
extension Ledger {
    public func aliasedJob(assetID: UUID, destinationID: UUID) throws -> JobRecord? {
        guard let row = try db.rows("SELECT job_id FROM aliases WHERE asset_id=? AND destination_id=?", [assetID.sql, destinationID.sql]).first else { return nil }
        guard let id = UUID(uuidString: try row.string("job_id")) else { throw CoreError.invalidContract }
        return try loadJob(id)
    }
    public func hasRetainedTransfers(jobID: UUID) throws -> Bool {
        try !db.rows("SELECT id FROM transfers WHERE job_id=? LIMIT 1", [jobID.sql]).isEmpty
    }
    public func attemptHistoryPage(jobID: UUID, beforeCursor: Int64? = nil, limit: Int = 50) throws -> [AttemptHistoryRow] {
        guard (1...100).contains(limit) else { throw CoreError.invalidContract }
        return try db.rows("SELECT rowid AS cursor,* FROM attempts WHERE job_id=? AND rowid<? ORDER BY rowid DESC LIMIT ?",
            [jobID.sql, .integer(beforeCursor ?? Int64.max), .integer(Int64(limit))]).map { row in
            guard let cycle = UUID(uuidString: try row.string("cycle")), let started = row.double("started") else { throw CoreError.invalidContract }
            let failure: SafeFailure?
            if case .blob = row.values["failure"] { failure = try db.decode(SafeFailure.self, row, "failure") } else { failure = nil }
            return AttemptHistoryRow(cursor: row.int("cursor"), cycleID: cycle, number: Int(row.int("number")),
                startedAt: Date(timeIntervalSince1970: started), endedAt: row.double("ended").map(Date.init(timeIntervalSince1970:)),
                suspended: row.int("suspended") == 1, failure: failure)
        }
    }
    public func currentLibraryScan() throws -> CurrentLibraryScan? {
        guard let row = try db.rows("SELECT s.id,s.complete FROM scans s JOIN meta m ON m.value=s.id WHERE m.key='scan'").first else { return nil }
        guard let id = UUID(uuidString: try row.string("id")) else { throw CoreError.invalidContract }
        return CurrentLibraryScan(id: id, complete: row.int("complete") == 1)
    }
    /// Bounded keyset enumeration for cleanup/credential-change preflight.
    /// Missing credentials and deselection do not prove native input ownership ended.
    public func destinationInventoryPage(afterID: UUID? = nil, limit: Int = 50) throws -> [DestinationInventoryRow] {
        guard (1...100).contains(limit) else { throw CoreError.invalidContract }
        return try db.rows("""
            SELECT d.*,(SELECT COUNT(*) FROM transfers t WHERE t.destination_id=d.id) AS retained
            FROM destinations d WHERE d.id>?
            AND (d.selected=1 OR EXISTS(SELECT 1 FROM transfers t WHERE t.destination_id=d.id))
            ORDER BY d.id LIMIT ?
            """, [.text(afterID?.uuidString ?? ""), .integer(Int64(limit))]).map {
            DestinationInventoryRow(destination: try db.decode(Destination.self, $0, "body"),
                selected: $0.int("selected") == 1, enabled: $0.int("enabled") == 1,
                recoveryComplete: $0.int("recovered") == 1, retainedTransferCount: Int($0.int("retained")))
        }
    }
    /// Export/planning may fail before content hashes exist, so no valid upload job
    /// can yet be built. Keep that obligation visible; do not invent a fake hash/job.
    public func recordSourceFailure(assetID: UUID, destinationIDs: [UUID], error: SafeFailure, permanent: Bool) throws {
        guard !destinationIDs.isEmpty, destinationIDs.count <= 2, Set(destinationIDs).count == destinationIDs.count else { throw CoreError.invalidContract }
        try transaction {
            for destinationID in destinationIDs {
                try db.execute("INSERT INTO source_failures(asset_id,destination_id,error,permanent,occurred) VALUES(?,?,?,?,?) ON CONFLICT(asset_id,destination_id) DO UPDATE SET error=excluded.error,permanent=excluded.permanent,occurred=excluded.occurred", [assetID.sql, destinationID.sql, try db.encode(error), .integer(permanent ? 1 : 0), Date().sql])
                try record(.preparation, context: EventContext(origin: .source, destinationID: destinationID, assetID: assetID), severity: .error, decision: permanent ? .skip : .wait, failure: error)
            }
        }
    }
    /// A completed planning cursor must revisit retryable source work on refresh.
    /// Historical, disabled and already-confirmed obligations are not new work.
    public func hasRetryableSourceFailures() throws -> Bool {
        try !db.rows("""
            SELECT 1 FROM source_failures f JOIN assets a ON a.id=f.asset_id
            JOIN destinations d ON d.id=f.destination_id
            WHERE f.permanent=0 AND d.selected=1 AND d.enabled=1
              AND NOT EXISTS(SELECT 1 FROM excluded_assets e WHERE e.provider=d.provider AND e.local_id=a.local_id)
              AND a.scan_id=(SELECT value FROM meta WHERE key='scan')
              AND NOT EXISTS(SELECT 1 FROM aliases x JOIN jobs j ON j.id=x.job_id
                  WHERE x.asset_id=a.id AND x.destination_id=d.id AND j.state='confirmed')
            LIMIT 1
            """).isEmpty
    }
    public func sourceFailurePage(beforeCursor: Int64? = nil, provider: Provider? = nil, kind: MediaKind? = nil, limit: Int = 50, permanent: Bool? = nil) throws -> [SourceFailureRow] {
        guard (1...100).contains(limit) else { throw CoreError.invalidContract }
        var clauses = ["f.seq<?", "d.selected=1", "a.scan_id=(SELECT value FROM meta WHERE key='scan')",
                       "NOT EXISTS(SELECT 1 FROM aliases x JOIN jobs j ON j.id=x.job_id WHERE x.asset_id=a.id AND x.destination_id=d.id AND j.state='confirmed')"]
        var args: [SQLValue] = [.integer(beforeCursor ?? Int64.max)]
        if let provider { clauses.append("d.provider=?"); args.append(.text(provider.rawValue)) }
        if let kind { clauses.append("a.kind=?"); args.append(.text(kind.rawValue)) }
        if let permanent { clauses.append("f.permanent=?"); args.append(.integer(permanent ? 1 : 0)) }
        args.append(.integer(Int64(limit)))
        return try db.rows("SELECT f.*,a.body AS asset_body,d.body AS destination_body,r.body AS recipe FROM source_failures f JOIN assets a ON a.id=f.asset_id JOIN destinations d ON d.id=f.destination_id LEFT JOIN source_recipes r ON r.asset_id=a.id WHERE \(clauses.joined(separator: " AND ")) ORDER BY f.seq DESC LIMIT ?", args).map {
            guard let occurred = $0.double("occurred") else { throw CoreError.invalidContract }
            let recipe: Data?
            if case .blob = $0.values["recipe"] { recipe = try $0.data("recipe") } else { recipe = nil }
            return SourceFailureRow(recipeData: recipe, cursor: $0.int("seq"), asset: try db.decode(AssetIdentity.self, $0, "asset_body"), destination: try db.decode(Destination.self, $0, "destination_body"), error: try db.decode(SafeFailure.self, $0, "error"), permanent: $0.int("permanent") == 1, occurredAt: Date(timeIntervalSince1970: occurred))
        }
    }
    /// P3 scans first and then plans canonical returned identities in bounded pages.
    /// Never synthesize another UUID when resolving a PHAsset after registration.
    public func scannedAssetPage(scanID: UUID, afterCursor: Int64 = 0, limit: Int = 200) throws -> [ScannedAssetRow] {
        guard afterCursor >= 0, (1...200).contains(limit) else { throw CoreError.invalidContract }
        return try db.rows("SELECT rowid AS cursor,body FROM assets WHERE scan_id=? AND rowid>? ORDER BY rowid LIMIT ?", [scanID.sql, .integer(afterCursor), .integer(Int64(limit))]).map {
            ScannedAssetRow(cursor: $0.int("cursor"), asset: try db.decode(AssetIdentity.self, $0, "body"))
        }
    }
    public func snapshot() throws -> LedgerSnapshot {
        if let cachedSnapshot, cachedSnapshot.revision == db.snapshotRevision {
            reusedSnapshots &+= 1; return cachedSnapshot.value
        }
        computedSnapshots &+= 1
        // Single actor turn, no awaits: state cannot change between these queries.
        let scan = try db.rows("SELECT s.* FROM scans s JOIN meta m ON m.value=s.id WHERE m.key='scan'").first
        let scanned = scan?.int("complete") == 1
        let totals = scanned ? try db.rows("SELECT COUNT(*) AS n, COALESCE(SUM(kind='photo'),0) AS photos, COALESCE(SUM(kind='video'),0) AS videos FROM assets WHERE scan_id=(SELECT value FROM meta WHERE key='scan')").first : nil
        let total = totals.map { Int($0.int("n")) }
        var providers: [ProviderSnapshot] = []
        for provider in Provider.allCases {
            let row = try db.rows("SELECT * FROM destinations WHERE provider=? AND selected=1", [.text(provider.rawValue)]).first
            let id = try row.map { row -> UUID in
                guard let id = UUID(uuidString: try row.string("id")) else { throw CoreError.invalidContract }; return id
            }
            let ready = try exclusionReady(provider)
            let photos = scanned && id != nil && ready ? try counts(destinationID: id!, kind: .photo) : nil
            let videos = scanned && id != nil && ready ? try counts(destinationID: id!, kind: .video) : nil
            let last = try id.flatMap { try db.rows("SELECT MAX(last_confirmed) AS date FROM jobs WHERE destination_id=?", [$0.sql]).first?.double("date") }.map(Date.init(timeIntervalSince1970:))
            let failure = try row.flatMap { row -> SafeFailure? in
                if case .blob = row.values["blocked"] { return try db.decode(SafeFailure.self, row, "blocked") }; return nil
            }
            let retained = try id.flatMap { try db.rows("""
                SELECT COUNT(*) AS total, COALESCE(SUM(json_extract(CAST(c.body AS TEXT),'$.phase')='uncertain'
                    AND json_extract(CAST(c.body AS TEXT),'$.inputsTerminal')=0),0) AS unresolved
                FROM transfers t LEFT JOIN provider_checkpoints c ON c.transfer_id=t.id AND c.destination_id=t.destination_id
                WHERE t.destination_id=?
                """, [$0.sql]).first }
            providers.append(ProviderSnapshot(provider: provider, destinationID: id, enabled: row?.int("enabled") == 1,
                                              recoveryComplete: row?.int("recovered") == 1, blockedReason: failure,
                                              resumeAt: row?.double("resume_at").map(Date.init(timeIntervalSince1970:)),
                                              photos: photos, videos: videos, lastConfirmedAt: last,
                                              retainedTransfers: Int(retained?.int("total") ?? 0),
                                              protectedUnresolvedTransfers: Int(retained?.int("unresolved") ?? 0)))
        }
        let both: Int?
        if scanned, providers.allSatisfy({ $0.destinationID != nil }) {
            both = Int(try db.rows("""
                SELECT COUNT(*) AS n FROM assets a WHERE a.scan_id=(SELECT value FROM meta WHERE key='scan')
                AND EXISTS(SELECT 1 FROM aliases x JOIN jobs j ON j.id=x.job_id JOIN destinations d ON d.id=j.destination_id WHERE x.asset_id=a.id AND j.state='confirmed' AND d.selected=1 AND d.provider='google')
                AND EXISTS(SELECT 1 FROM aliases x JOIN jobs j ON j.id=x.job_id JOIN destinations d ON d.id=j.destination_id WHERE x.asset_id=a.id AND j.state='confirmed' AND d.selected=1 AND d.provider='telegram')
                """).first!.int("n"))
        } else { both = nil }
        let value = LedgerSnapshot(scanned: scanned, scanStartedAt: scan?.double("created").map(Date.init(timeIntervalSince1970:)), libraryTotal: total,
            libraryPhotoTotal: totals.map { Int($0.int("photos")) }, libraryVideoTotal: totals.map { Int($0.int("videos")) },
            savedToBoth: both, providers: providers)
        cachedSnapshot = (db.snapshotRevision, value)
        return value
    }
    /// Process-local measurement only; never used to construct upload counts.
    public func snapshotPerformance() -> (computed: UInt64, reused: UInt64) { (computedSnapshots, reusedSnapshots) }
    private func counts(destinationID: UUID, kind: MediaKind) throws -> MediaCounts {
        let row = try db.rows("""
            SELECT COUNT(*) AS total,
            COALESCE(SUM(j.state='confirmed'),0) AS confirmed,
            COALESCE(SUM(j.state='failed' OR (f.permanent=1 AND j.state IS NOT 'confirmed')),0) AS failed,
            COALESCE(SUM(j.state IS NOT 'confirmed' AND j.state IS NOT 'failed' AND (f.permanent IS NULL OR f.permanent=0) AND (j.state IN ('waiting','reconciling','delayed') OR f.permanent=0)),0) AS waiting,
            COALESCE(SUM(j.state='confirmed' AND EXISTS(SELECT 1 FROM obligations o JOIN receipts r ON r.tag=o.tag AND r.destination_id=j.destination_id WHERE o.job_id=j.id AND r.kind='uploaded')),0) AS uploaded
            FROM assets a LEFT JOIN aliases x ON x.asset_id=a.id AND x.destination_id=?
            LEFT JOIN jobs j ON j.id=x.job_id
            LEFT JOIN source_failures f ON f.asset_id=a.id AND f.destination_id=?
            WHERE a.kind=? AND a.scan_id=(SELECT value FROM meta WHERE key='scan')
            AND NOT EXISTS(SELECT 1 FROM excluded_assets e WHERE e.local_id=a.local_id
                AND e.provider=(SELECT provider FROM destinations WHERE id=?))
            """, [destinationID.sql, destinationID.sql, .text(kind.rawValue), destinationID.sql]).first!
        let confirmed = Int(row.int("confirmed")), uploaded = Int(row.int("uploaded"))
        let excluded = Int(try db.rows("""
            SELECT COUNT(*) AS n FROM assets a WHERE a.kind=?
            AND a.scan_id=(SELECT value FROM meta WHERE key='scan')
            AND EXISTS(SELECT 1 FROM excluded_assets e WHERE e.local_id=a.local_id
                AND e.provider=(SELECT provider FROM destinations WHERE id=?))
            """, [.text(kind.rawValue), destinationID.sql]).first!.int("n"))
        return MediaCounts(total: Int(row.int("total")), confirmed: confirmed, uploaded: uploaded,
                           alreadyPresent: confirmed - uploaded, failed: Int(row.int("failed")), waiting: Int(row.int("waiting")), excluded: excluded)
    }
    public func failurePage(beforeCursor: Int64? = nil, provider: Provider? = nil, kind: MediaKind? = nil,
                            limit: Int = 50, states: [JobState]? = nil) throws -> [FailureRow] {
        guard (1...100).contains(limit) else { throw CoreError.invalidContract }
        var clauses = ["x.rowid<?", "d.selected=1", "j.state IN ('failed','waiting','reconciling','delayed')", "a.scan_id=(SELECT value FROM meta WHERE key='scan')"]
        var args: [SQLValue] = [.integer(beforeCursor ?? Int64.max)]
        if let provider { clauses.append("d.provider=?"); args.append(.text(provider.rawValue)) }
        if let kind { clauses.append("a.kind=?"); args.append(.text(kind.rawValue)) }
        if let states {
            guard !states.isEmpty, states.count <= 4, states.allSatisfy({ [.failed, .waiting, .reconciling, .delayed].contains($0) }) else { throw CoreError.invalidContract }
            clauses.append("j.state IN (\(states.map { _ in "?" }.joined(separator: ",")))")
            args.append(contentsOf: states.map { .text($0.rawValue) })
        }
        args.append(.integer(Int64(limit)))
        return try db.rows("SELECT j.*,x.rowid AS cursor,j.id AS job_id,a.body AS asset_body,d.body AS destination_body,r.body AS recipe,EXISTS(SELECT 1 FROM transfers t WHERE t.job_id=j.id) AS retained,(SELECT COUNT(*) FROM obligations o WHERE o.job_id=j.id AND o.status='confirmed') AS confirmed,(SELECT COUNT(*) FROM obligations o WHERE o.job_id=j.id) AS required FROM aliases x JOIN jobs j ON j.id=x.job_id JOIN assets a ON a.id=x.asset_id JOIN destinations d ON d.id=j.destination_id LEFT JOIN source_recipes r ON r.asset_id=a.id WHERE \(clauses.joined(separator: " AND ")) ORDER BY x.rowid DESC LIMIT ?", args).map { row in
            guard let id = UUID(uuidString: try row.string("job_id")) else { throw CoreError.invalidContract }
            let failure: SafeFailure?
            if case .blob = row.values["failure"] { failure = try db.decode(SafeFailure.self, row, "failure") } else { failure = nil }
            guard let cycle = UUID(uuidString: try row.string("cycle")),
                  let state = JobState(rawValue: try row.string("state")) else { throw CoreError.invalidContract }
            let asset = try db.decode(AssetIdentity.self, row, "asset_body")
            let job = JobRecord(id: id, destination: try db.decode(Destination.self, row, "destination_body"),
                asset: asset, plan: try db.decode(UploadPlan.self, row, "plan"), state: state, cycleID: cycle,
                attempts: Int(row.int("attempts")), retryAt: row.double("retry_at").map(Date.init(timeIntervalSince1970:)))
            let recipe: Data?
            if case .blob = row.values["recipe"] { recipe = try row.data("recipe") } else { recipe = nil }
            return FailureRow(recipeData: recipe, retained: row.int("retained") == 1,
                              cursor: row.int("cursor"), job: job, asset: asset, failure: failure,
                              confirmedResources: Int(row.int("confirmed")), requiredResources: Int(row.int("required")))
        }
    }
}
