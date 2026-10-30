import Foundation

public struct AlbumExclusionRules: Sendable {
    public let revision: Int64
    public let albumIDs: [String]
}

extension Ledger {
    public func albumExclusionRules(_ provider: Provider) throws -> AlbumExclusionRules {
        let revision = try db.rows("SELECT revision FROM exclusion_state WHERE provider=?", [.text(provider.rawValue)]).first?.int("revision") ?? 0
        let ids = try db.rows("SELECT album_id FROM album_exclusions WHERE provider=? ORDER BY album_id", [.text(provider.rawValue)]).map { try $0.string("album_id") }
        return AlbumExclusionRules(revision: revision, albumIDs: ids)
    }
    public func setAlbumExclusions(_ rules: [Provider: Set<String>]) throws {
        try transaction {
            for provider in Provider.allCases {
                let ids = rules[provider] ?? []
                guard ids.count <= 500, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }) else { throw CoreError.invalidContract }
                let old = try albumExclusionRules(provider)
                if Set(old.albumIDs) == ids { continue }
                guard old.revision < Int64.max else { throw CoreError.invalidContract }
                try db.execute("DELETE FROM album_exclusions WHERE provider=?", [.text(provider.rawValue)])
                for id in ids { try db.execute("INSERT INTO album_exclusions VALUES(?,?)", [.text(provider.rawValue), .text(id)]) }
                try db.execute("INSERT INTO exclusion_state VALUES(?,?,1) ON CONFLICT(provider) DO UPDATE SET revision=excluded.revision,pending=1", [.text(provider.rawValue), .integer(old.revision + 1)])
            }
        }
    }
    public func exclusionReady(_ provider: Provider) throws -> Bool {
        try db.rows("SELECT pending FROM exclusion_state WHERE provider=?", [.text(provider.rawValue)]).first?.int("pending") != 1
    }
    public func beginExclusionRefresh(_ provider: Provider, revision: Int64) throws {
        try transaction {
            guard try albumExclusionRules(provider).revision == revision else { throw CoreError.staleMapping }
            try db.execute("INSERT INTO exclusion_state VALUES(?,?,1) ON CONFLICT(provider) DO UPDATE SET pending=1", [.text(provider.rawValue), .integer(revision)])
            try db.execute("DELETE FROM exclusion_build WHERE provider=?", [.text(provider.rawValue)])
        }
    }
    public func stageExcludedAssets(_ ids: [String], provider: Provider, revision: Int64) throws {
        guard ids.count <= 200 else { throw CoreError.invalidContract }
        try transaction {
            guard try albumExclusionRules(provider).revision == revision else { throw CoreError.staleMapping }
            for id in ids {
                guard !id.isEmpty, id.utf8.count <= 2048 else { throw CoreError.invalidContract }
                try db.execute("INSERT OR IGNORE INTO exclusion_build VALUES(?,?)", [.text(provider.rawValue), .text(id)])
            }
        }
    }
    public func finishExclusionRefresh(_ provider: Provider, revision: Int64) throws {
        try transaction {
            guard try albumExclusionRules(provider).revision == revision else { throw CoreError.staleMapping }
            try db.execute("DELETE FROM excluded_assets WHERE provider=?", [.text(provider.rawValue)])
            try db.execute("INSERT INTO excluded_assets SELECT * FROM exclusion_build WHERE provider=?", [.text(provider.rawValue)])
            try db.execute("DELETE FROM exclusion_build WHERE provider=?", [.text(provider.rawValue)])
            try db.execute("UPDATE exclusion_state SET pending=0 WHERE provider=?", [.text(provider.rawValue)])
        }
    }
    public func updateAssetExclusion(_ localID: String, provider: Provider, revision: Int64, excluded: Bool) throws {
        try transaction {
            guard try albumExclusionRules(provider).revision == revision else { throw CoreError.staleMapping }
            if excluded { try db.execute("INSERT OR IGNORE INTO excluded_assets VALUES(?,?)", [.text(provider.rawValue), .text(localID)]) }
            else { try db.execute("DELETE FROM excluded_assets WHERE provider=? AND local_id=?", [.text(provider.rawValue), .text(localID)]) }
        }
    }
    public func deferExcludedJob(_ id: UUID) throws {
        try transaction {
            let job = try loadJob(id)
            guard job.state != .confirmed, try !hasRetainedTransfers(jobID: id) else { throw CoreError.invalidTransition }
            try db.execute("UPDATE jobs SET state='reconciling',retry_at=NULL WHERE id=?", [id.sql])
            try db.execute("UPDATE attempts SET suspended=1 WHERE job_id=? AND ended IS NULL", [id.sql])
        }
    }
}
