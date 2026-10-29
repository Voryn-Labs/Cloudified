import Foundation

public enum GoogleRemoteQuality: String, Codable, Equatable, Sendable { case original, storageSaver, unknown }
public struct GoogleRemoteItem: Codable, Equatable, Sendable {
    public let key: String
    public let filename: String
    public let bytes: Int64
    public let timestamp: Double
    public let width: Int
    public let height: Int
    public let quality: GoogleRemoteQuality
    public init(key: String, filename: String, bytes: Int64, timestamp: Double, width: Int, height: Int, quality: GoogleRemoteQuality) {
        self.key = key; self.filename = filename; self.bytes = bytes; self.timestamp = timestamp
        self.width = width; self.height = height; self.quality = quality
    }
    public var valid: Bool {
        !key.isEmpty && key.utf8.count <= 2048 && !filename.isEmpty && filename.utf8.count <= 512 &&
        bytes > 0 && timestamp.isFinite && abs(timestamp) < 253_402_300_800 &&
        (0...1_000_000).contains(width) && (0...1_000_000).contains(height)
    }
    static func name(_ value: String) -> String { value.precomposedStringWithCanonicalMapping.lowercased() }
}
public struct GoogleLibraryCursor: Codable, Equatable, Sendable {
    public var scope: String
    public var initial = true
    public var resume = ""
    public var sync = ""
    public var nextSync = ""
    public var rows = 0
    public var payloadBytes: Int64 = 0
    public var pages = 0
    public var complete = false
    public var partial = false
    public var updated: Date?
    public init(scope: String) { self.scope = scope }
}
public struct GoogleLibraryPage: Sendable {
    public let resume: String
    public let sync: String
    public let items: [GoogleRemoteItem]
    public let deleted: [String]
    public let skipped: Int
    public init(resume: String, sync: String, items: [GoogleRemoteItem], deleted: [String], skipped: Int = 0) {
        self.resume = resume; self.sync = sync; self.items = items; self.deleted = deleted; self.skipped = skipped
    }
}

/// Disposable metadata only. This connection never owns ledger receipts or media.
public actor GoogleRemoteIndex {
    private let db: SQLite
    public static let maximumRows = 100_000
    public static let maximumPayloadBytes: Int64 = 16 * 1024 * 1024
    public init(url: URL) throws {
        guard url.lastPathComponent == "google-metadata.sqlite" else { throw CoreError.invalidContract }
        let db = try SQLite(url: url)
        guard try db.rows("PRAGMA page_size").first?.int("page_size") == 4096 else { throw CoreError.invalidContract }
        try db.execute("PRAGMA max_page_count=8192")
        try db.execute("PRAGMA wal_autocheckpoint=16")
        try db.execute("PRAGMA journal_size_limit=1048576")
        try db.execute("CREATE TABLE IF NOT EXISTS catalog_state(id INTEGER PRIMARY KEY CHECK(id=1),body BLOB NOT NULL)")
        try db.execute("CREATE TABLE IF NOT EXISTS catalog_items(key TEXT PRIMARY KEY,name TEXT NOT NULL,body BLOB NOT NULL)")
        try db.execute("CREATE INDEX IF NOT EXISTS catalog_names ON catalog_items(name)")
        try db.execute("CREATE TABLE IF NOT EXISTS catalog_cursors(token TEXT PRIMARY KEY)")
        try db.execute("CREATE TABLE IF NOT EXISTS catalog_overrides(tag TEXT PRIMARY KEY,expires REAL NOT NULL)")
        self.db = db
    }
    private func load() throws -> GoogleLibraryCursor? {
        try db.rows("SELECT body FROM catalog_state WHERE id=1").first.map { try db.decode(GoogleLibraryCursor.self, $0, "body") }
    }
    private func save(_ cursor: GoogleLibraryCursor) throws {
        try db.execute("INSERT INTO catalog_state VALUES(1,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body", [try db.encode(cursor)])
    }
    public func bind(_ scope: String) throws -> GoogleLibraryCursor {
        guard UploadPlan.hex(scope, length: 64) else { throw CoreError.invalidContract }
        if let current = try load(), current.scope == scope { return current }
        let cursor = GoogleLibraryCursor(scope: scope)
        try db.transaction {
            for table in ["catalog_items", "catalog_cursors", "catalog_overrides", "catalog_state"] { try db.execute("DELETE FROM \(table)") }
            try save(cursor)
        }
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return cursor
    }
    public func cursor(scope: String, now: Date = Date()) throws -> GoogleLibraryCursor {
        var cursor = try bind(scope)
        if cursor.complete, let updated = cursor.updated, now.timeIntervalSince(updated) >= 900 {
            cursor.complete = false; cursor.resume = ""; cursor.nextSync = ""; cursor.pages = 0; cursor.partial = false
            try db.transaction { try db.execute("DELETE FROM catalog_cursors"); try save(cursor) }
        }
        return cursor
    }
    public func apply(_ page: GoogleLibraryPage, expected: GoogleLibraryCursor, now: Date = Date()) throws -> GoogleLibraryCursor {
        guard try load() == expected, !expected.complete, expected.pages < 512,
              page.items.count <= 5000, page.deleted.count <= 5000,
              page.resume.utf8.count <= 8192, page.sync.utf8.count <= 8192,
              page.skipped >= 0, page.items.allSatisfy(\.valid),
              page.resume.isEmpty || page.resume != expected.resume else { throw CoreError.invalidContract }
        var next = expected
        next.pages += 1; next.resume = page.resume; next.partial = next.partial || page.skipped > 0
        if !page.sync.isEmpty { next.nextSync = page.sync }
        if page.resume.isEmpty {
            guard !next.nextSync.isEmpty else { throw CoreError.invalidContract }
            next.complete = true; next.initial = false; next.sync = next.nextSync; next.updated = now
        }
        try db.transaction {
            if !page.resume.isEmpty {
                guard try db.rows("SELECT token FROM catalog_cursors WHERE token=?", [.text(page.resume)]).isEmpty else { throw CoreError.invalidContract }
                try db.execute("INSERT INTO catalog_cursors VALUES(?)", [.text(page.resume)])
            }
            for item in page.items {
                let body = try JSONEncoder().encode(item)
                guard body.count <= 4096 else { throw CoreError.invalidContract }
                let old = try db.rows("SELECT length(body) AS bytes FROM catalog_items WHERE key=?", [.text(item.key)]).first
                if old == nil { next.rows += 1 }
                next.payloadBytes += Int64(body.count) - (old?.int("bytes") ?? 0)
                try db.execute("INSERT INTO catalog_items VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET name=excluded.name,body=excluded.body", [.text(item.key), .text(GoogleRemoteItem.name(item.filename)), .blob(body)])
            }
            for key in page.deleted {
                guard !key.isEmpty, key.utf8.count <= 2048 else { throw CoreError.invalidContract }
                if let old = try db.rows("SELECT length(body) AS bytes FROM catalog_items WHERE key=?", [.text(key)]).first {
                    next.rows -= 1; next.payloadBytes -= old.int("bytes")
                    try db.execute("DELETE FROM catalog_items WHERE key=?", [.text(key)])
                }
            }
            guard next.rows <= Self.maximumRows, next.payloadBytes <= Self.maximumPayloadBytes else { throw CoreError.invalidContract }
            if next.complete { try db.execute("DELETE FROM catalog_cursors") }
            try save(next)
        }
        try db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        return next
    }
    public func candidate(scope: String, filename: String, timestamp: Double, width: Int, height: Int, bytes: Int64, now: Date = Date()) throws -> GoogleRemoteQuality? {
        guard let cursor = try load(), cursor.scope == scope, timestamp.isFinite,
              width > 0, height > 0, bytes > 0 else { return nil }
        if let updated = cursor.updated, now.timeIntervalSince(updated) > 86_400 { return nil }
        let rows = try db.rows("SELECT body FROM catalog_items WHERE name=? LIMIT 33", [.text(GoogleRemoteItem.name(filename))])
        guard rows.count <= 32 else { return .unknown }
        var quality: GoogleRemoteQuality?
        for row in rows {
            let item = try db.decode(GoogleRemoteItem.self, row, "body")
            let dimensionsMatch = (item.width == width && item.height == height) || (item.width == height && item.height == width)
            guard abs(item.timestamp - timestamp) <= 2, dimensionsMatch,
                  abs(Double(item.bytes) - Double(bytes)) <= max(65_536, Double(bytes) * 0.02) else { continue }
            if item.quality == .original { return .original }
            if quality == nil || item.quality == .unknown { quality = item.quality }
        }
        return quality
    }
    public func allowOriginal(scope: String, tags: [String], now: Date = Date()) throws {
        guard try load()?.scope == scope, tags.count <= 128, tags.allSatisfy({ UploadPlan.hex($0, length: 64) }) else { throw CoreError.invalidContract }
        try db.transaction {
            try db.execute("DELETE FROM catalog_overrides WHERE expires<=?", [now.sql])
            for tag in tags { try db.execute("INSERT INTO catalog_overrides VALUES(?,?) ON CONFLICT(tag) DO UPDATE SET expires=excluded.expires", [.text(tag), now.addingTimeInterval(604_800).sql]) }
            guard (try db.rows("SELECT COUNT(*) AS n FROM catalog_overrides").first?.int("n") ?? 0) <= 1024 else { throw CoreError.invalidContract }
        }
    }
    public func isAllowed(scope: String, tag: String, now: Date = Date()) throws -> Bool {
        guard try load()?.scope == scope else { return false }
        return try !db.rows("SELECT tag FROM catalog_overrides WHERE tag=? AND expires>?", [.text(tag), now.sql]).isEmpty
    }
}

extension Ledger {
    public func googleSourceRecipe(destinationID: UUID, tag: String) throws -> Data? {
        try db.rows("SELECT r.body FROM jobs j JOIN obligations o ON o.job_id=j.id JOIN source_recipes r ON r.asset_id=j.asset_id WHERE j.destination_id=? AND o.tag=? LIMIT 1", [destinationID.sql, .text(tag)]).first.map { try $0.data("body") }
    }
    public func googleOverrideTags(jobID: UUID, destinationID: UUID) throws -> [String] {
        let job = try loadJob(jobID)
        guard job.destination.id == destinationID, job.destination.provider == .google,
              let row = try db.rows("SELECT failure FROM jobs WHERE id=?", [jobID.sql]).first,
              try db.decode(SafeFailure.self, row, "failure").cause == .possibleOriginalMatch,
              try !hasRetainedTransfers(jobID: jobID) else { throw CoreError.invalidTransition }
        return job.plan.resources.map(\.tag)
    }
}
