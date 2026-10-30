import Foundation
import CSQLite

enum SQLValue { case text(String), integer(Int64), real(Double), blob(Data), null }
struct SQLRow {
    let values: [String: SQLValue]
    func string(_ key: String) throws -> String {
        guard case .text(let value) = values[key] else { throw CoreError.invalidContract }; return value
    }
    func int(_ key: String) -> Int64 { if case .integer(let value) = values[key] { return value }; return 0 }
    func double(_ key: String) -> Double? {
        if case .real(let value) = values[key] { return value }
        if case .integer(let value) = values[key] { return Double(value) }; return nil
    }
    func data(_ key: String) throws -> Data {
        guard case .blob(let value) = values[key] else { throw CoreError.invalidContract }; return value
    }
}

/// Actor-confined by Ledger. No escaping handles/statements, raw SQL errors or paths
/// in diagnostics. FULL synchronous WAL commits before observers can read receipts.
final class SQLite {
    private var handle: OpaquePointer?
    private(set) var snapshotRevision: UInt64 = 0
    private var updateCallbacks: UInt64 = 0
    private static let snapshotTables: Set<String> = ["destinations", "scans", "meta", "assets", "aliases", "jobs", "obligations", "receipts", "source_failures", "transfers", "provider_checkpoints", "excluded_assets", "exclusion_state"]
    init(url: URL) throws {
        let code = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK else { sqlite3_close(handle); handle = nil; throw CoreError.persistence(code) }
        sqlite3_busy_timeout(handle, 3_000)
        do {
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
        } catch { sqlite3_close(handle); handle = nil; throw error }
        // Runs synchronously on the actor-confined connection. Rollbacks may
        // invalidate unnecessarily, but can never leave stale cached counts.
        sqlite3_update_hook(handle, { context, _, _, table, _ in
            guard let context, let table else { return }
            let owner = Unmanaged<SQLite>.fromOpaque(context).takeUnretainedValue()
            owner.updateCallbacks &+= 1
            if SQLite.snapshotTables.contains(String(cString: table)) { owner.snapshotRevision &+= 1 }
        }, Unmanaged.passUnretained(self).toOpaque())
    }
    deinit { sqlite3_close(handle) }
    var lastID: Int64 { sqlite3_last_insert_rowid(handle) }
    var changes: Int { Int(sqlite3_changes(handle)) }
    func execute(_ sql: String, _ values: [SQLValue] = []) throws { _ = try rows(sql, values) }
    func rows(_ sql: String, _ values: [SQLValue] = []) throws -> [SQLRow] {
        let changesBefore = sqlite3_total_changes64(handle), callbacksBefore = updateCallbacks
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else { throw CoreError.persistence(prepared) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let text): result = text.withCString { sqlite3_bind_text(statement, index, $0, -1, transient) }
            case .integer(let number): result = sqlite3_bind_int64(statement, index, number)
            case .real(let number): result = sqlite3_bind_double(statement, index, number)
            case .blob(let data):
                if data.isEmpty { result = sqlite3_bind_zeroblob(statement, index, 0) }
                else { result = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), transient) } }
            case .null: result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw CoreError.persistence(result) }
        }
        var result: [SQLRow] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            guard code == SQLITE_ROW else { throw CoreError.persistence(code) }
            var columns: [String: SQLValue] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                guard let name = sqlite3_column_name(statement, index) else { throw CoreError.persistence(SQLITE_NOMEM) }
                let key = String(cString: name)
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: columns[key] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: columns[key] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    guard let text = sqlite3_column_text(statement, index) else { throw CoreError.persistence(SQLITE_NOMEM) }
                    let count = Int(sqlite3_column_bytes(statement, index))
                    guard sqlite3_errcode(handle) != SQLITE_NOMEM else { throw CoreError.persistence(SQLITE_NOMEM) }
                    columns[key] = .text(String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self))
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    if count == 0 { columns[key] = .blob(Data()) }
                    else {
                        guard let bytes = sqlite3_column_blob(statement, index) else { throw CoreError.persistence(SQLITE_NOMEM) }
                        columns[key] = .blob(Data(bytes: bytes, count: count))
                    }
                default: columns[key] = .null
                }
            }
            result.append(SQLRow(values: columns))
        }
        // SQLite can omit row callbacks for a whole-table DELETE optimization.
        // Invalidate conservatively when writes occurred without any callback.
        if sqlite3_total_changes64(handle) != changesBefore, updateCallbacks == callbacksBefore { snapshotRevision &+= 1 }
        return result
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); snapshotRevision &+= 1; throw error }
    }
    func encode<T: Encodable>(_ value: T) throws -> SQLValue { .blob(try JSONEncoder().encode(value)) }
    func decode<T: Decodable>(_ type: T.Type, _ row: SQLRow, _ column: String) throws -> T {
        try JSONDecoder().decode(type, from: row.data(column))
    }
}

extension UUID { var sql: SQLValue { .text(uuidString) } }
extension Date { var sql: SQLValue { .real(timeIntervalSince1970) } }

enum Schema {
    static func install(_ db: SQLite) throws {
        let version = try db.rows("PRAGMA user_version").first?.int("user_version") ?? 0
        guard version <= 7 else { throw CoreError.invalidContract }
        guard version < 7 else { return }
        try db.transaction {
            if version == 0 {
                for statement in statements { try db.execute(statement) }
            } else if version == 1 {
                // Preserve P2 v1 receipts/attempts/transport holds; never reset the
                // database to install source failures and verified cache metadata.
                try db.execute(sourceFailureTable)
                let columns = try db.rows("PRAGMA table_info(staged)").map { try $0.string("name") }
                if !columns.contains("content") { try db.execute("ALTER TABLE staged ADD COLUMN content BLOB") }
                for column in ["content_sha256", "content_sha1", "derived_from"] where !columns.contains(column) {
                    try db.execute("ALTER TABLE staged ADD COLUMN \(column) TEXT")
                }
                let reservationColumns = try db.rows("PRAGMA table_info(reservations)").map { try $0.string("name") }
                if !reservationColumns.contains("derived_from") { try db.execute("ALTER TABLE reservations ADD COLUMN derived_from TEXT") }
                try db.execute(contentIndex)
            }
            for statement in providerStatements { try db.execute(statement) }
            // v4 counts all diagnostic events; receipts/attempts/failure state live
            // in separate durable tables and are never rotated by this budget.
            try db.execute("UPDATE log_budget SET byte_used=(SELECT COALESCE(SUM(size),0) FROM events) WHERE id=1")
            // v5 is a recovery capability fence: older foreground-only app
            // versions must not release inputs owned by a surviving OS session.
            // Tables, receipts, attempts and checkpoints remain intact.
            for statement in exclusionStatements { try db.execute(statement) }
            // v7 fences new local-capacity failure/diagnostic values from older decoders.
            try db.execute("PRAGMA user_version=7")
        }
    }
    static let exclusionStatements = [
        "CREATE TABLE IF NOT EXISTS album_exclusions(provider TEXT NOT NULL,album_id TEXT NOT NULL,PRIMARY KEY(provider,album_id))",
        "CREATE TABLE IF NOT EXISTS exclusion_state(provider TEXT PRIMARY KEY,revision INTEGER NOT NULL,pending INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS excluded_assets(provider TEXT NOT NULL,local_id TEXT NOT NULL,PRIMARY KEY(provider,local_id))",
        "CREATE TABLE IF NOT EXISTS exclusion_build(provider TEXT NOT NULL,local_id TEXT NOT NULL,PRIMARY KEY(provider,local_id))"
    ]
    static let providerStatements = [
        "CREATE TABLE IF NOT EXISTS transport_reservations(id TEXT PRIMARY KEY,bytes INTEGER NOT NULL)",
        "CREATE TABLE IF NOT EXISTS provider_bindings(destination_id TEXT PRIMARY KEY REFERENCES destinations(id),profile TEXT NOT NULL,scope BLOB NOT NULL)",
        "CREATE TABLE IF NOT EXISTS provider_checkpoints(destination_id TEXT NOT NULL REFERENCES destinations(id),tag TEXT NOT NULL,transfer_id TEXT NOT NULL,body BLOB NOT NULL,PRIMARY KEY(destination_id,tag))",
        "CREATE TABLE IF NOT EXISTS remote_scans(destination_id TEXT PRIMARY KEY REFERENCES destinations(id),epoch TEXT NOT NULL,complete INTEGER NOT NULL DEFAULT 0)",
        "CREATE TABLE IF NOT EXISTS remote_index(destination_id TEXT NOT NULL REFERENCES destinations(id),tag TEXT NOT NULL,reference BLOB NOT NULL,PRIMARY KEY(destination_id,tag))"
    ]
    static let sourceFailureTable = "CREATE TABLE IF NOT EXISTS source_failures(seq INTEGER PRIMARY KEY AUTOINCREMENT, asset_id TEXT NOT NULL REFERENCES assets(id), destination_id TEXT NOT NULL REFERENCES destinations(id), error BLOB NOT NULL, permanent INTEGER NOT NULL, occurred REAL NOT NULL, UNIQUE(asset_id,destination_id))"
    static let contentIndex = "CREATE INDEX IF NOT EXISTS staged_content ON staged(content_sha256,content_sha1,bytes)"
    static let statements = [
        "CREATE TABLE destinations(id TEXT PRIMARY KEY, provider TEXT NOT NULL, fingerprint TEXT NOT NULL, body BLOB NOT NULL, enabled INTEGER NOT NULL DEFAULT 1, selected INTEGER NOT NULL DEFAULT 0, recovered INTEGER NOT NULL DEFAULT 0, blocked BLOB, resume_at REAL, UNIQUE(provider,fingerprint))",
        "CREATE UNIQUE INDEX selected_provider ON destinations(provider) WHERE selected=1",
        "CREATE TABLE scans(id TEXT PRIMARY KEY, complete INTEGER NOT NULL DEFAULT 0, created REAL NOT NULL)",
        "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        "CREATE TABLE assets(id TEXT PRIMARY KEY, local_id TEXT NOT NULL, generation TEXT NOT NULL, kind TEXT NOT NULL, body BLOB NOT NULL, scan_id TEXT NOT NULL REFERENCES scans(id), UNIQUE(local_id,generation))",
        "CREATE INDEX assets_scan ON assets(scan_id,kind)",
        "CREATE TABLE source_recipes(asset_id TEXT PRIMARY KEY REFERENCES assets(id), body BLOB NOT NULL)",
        sourceFailureTable,
        "CREATE TABLE jobs(seq INTEGER PRIMARY KEY AUTOINCREMENT, id TEXT NOT NULL UNIQUE, destination_id TEXT NOT NULL REFERENCES destinations(id), asset_id TEXT NOT NULL REFERENCES assets(id), coverage TEXT NOT NULL, plan BLOB NOT NULL, state TEXT NOT NULL, cycle TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0 CHECK(attempts BETWEEN 0 AND 3), retry_at REAL, failure BLOB, last_confirmed REAL, UNIQUE(destination_id,coverage))",
        "CREATE INDEX ready_jobs ON jobs(destination_id,state,retry_at,seq)",
        "CREATE TABLE aliases(job_id TEXT NOT NULL REFERENCES jobs(id), asset_id TEXT NOT NULL REFERENCES assets(id), destination_id TEXT NOT NULL REFERENCES destinations(id), PRIMARY KEY(job_id,asset_id), UNIQUE(asset_id,destination_id))",
        "CREATE INDEX aliases_asset ON aliases(asset_id)",
        "CREATE TABLE obligations(job_id TEXT NOT NULL REFERENCES jobs(id), resource_id TEXT NOT NULL, tag TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'unknown' CHECK(status IN ('unknown','absent','sending','confirmed')), PRIMARY KEY(job_id,resource_id), UNIQUE(job_id,tag))",
        "CREATE TABLE receipts(destination_id TEXT NOT NULL REFERENCES destinations(id), tag TEXT NOT NULL, kind TEXT NOT NULL, body BLOB NOT NULL, confirmed_at REAL NOT NULL, PRIMARY KEY(destination_id,tag))",
        "CREATE TABLE attempts(job_id TEXT NOT NULL REFERENCES jobs(id), cycle TEXT NOT NULL, number INTEGER NOT NULL, started REAL NOT NULL, ended REAL, suspended INTEGER NOT NULL DEFAULT 0, failure BLOB, PRIMARY KEY(job_id,cycle,number))",
        "CREATE TABLE failures(seq INTEGER PRIMARY KEY AUTOINCREMENT, job_id TEXT NOT NULL REFERENCES jobs(id), cycle TEXT NOT NULL, attempt INTEGER NOT NULL, occurred REAL NOT NULL, body BLOB NOT NULL)",
        "CREATE TABLE runs(id TEXT PRIMARY KEY, started REAL NOT NULL, ended REAL, version TEXT NOT NULL, revision TEXT NOT NULL, outcome TEXT)",
        "CREATE TABLE events(seq INTEGER PRIMARY KEY AUTOINCREMENT, occurred REAL NOT NULL, origin TEXT NOT NULL, severity TEXT NOT NULL, run_id TEXT, critical INTEGER NOT NULL, size INTEGER NOT NULL, body BLOB NOT NULL)",
        "CREATE INDEX events_filter ON events(origin,severity,seq)",
        "CREATE INDEX rotating_events ON events(seq) WHERE critical=0",
        "CREATE TABLE log_budget(id INTEGER PRIMARY KEY CHECK(id=1), byte_used INTEGER NOT NULL DEFAULT 0, pruned INTEGER NOT NULL DEFAULT 0, first_pruned REAL)",
        "INSERT INTO log_budget(id) VALUES(1)",
        "CREATE TABLE staged(id TEXT PRIMARY KEY, relative_path TEXT NOT NULL UNIQUE, bytes INTEGER NOT NULL, content BLOB, content_sha256 TEXT, content_sha1 TEXT, derived_from TEXT, oversized INTEGER NOT NULL DEFAULT 0, recoverable INTEGER NOT NULL DEFAULT 0, deleting INTEGER NOT NULL DEFAULT 0)",
        contentIndex,
        "CREATE TABLE transfers(id TEXT PRIMARY KEY, destination_id TEXT NOT NULL REFERENCES destinations(id), job_id TEXT NOT NULL REFERENCES jobs(id), resource_id TEXT NOT NULL)",
        "CREATE TABLE holds(transfer_id TEXT NOT NULL REFERENCES transfers(id), file_id TEXT NOT NULL REFERENCES staged(id), destination_id TEXT NOT NULL REFERENCES destinations(id), job_id TEXT NOT NULL REFERENCES jobs(id), PRIMARY KEY(transfer_id,file_id))",
        "CREATE TABLE reservations(id TEXT PRIMARY KEY, bytes INTEGER NOT NULL, derived_from TEXT, oversized INTEGER NOT NULL CHECK(oversized IN (0,1)))",
        "CREATE UNIQUE INDEX one_oversized ON reservations(oversized) WHERE oversized=1"
    ]
}
