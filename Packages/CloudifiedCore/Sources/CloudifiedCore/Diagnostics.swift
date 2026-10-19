import Foundation

public enum DiagnosticReportFocus: Sendable { case lifecycle, failures }

private enum DiagnosticTimeline {
    static let stages: [DiagnosticStage] = [
        .startup, .providerChange, .googleConnect, .googleMasterToken, .googlePhotosToken,
        .googleAuthenticate, .googleReadAccess, .googleMapping, .googleRecovery,
        .telegramStart, .telegramStorage, .telegramNativeCreate, .telegramAuthorization,
        .telegramParameters, .telegramAuthState, .diagnosticUpload, .backgroundContinuation,
        .automaticBackground, .networkPolicy, .telegramCensus, .telegramRecovery, .telegramProtocol, .telegramLocalReset, .startupInventory
    ]
    static let operations: [EventOperation] = [
        .appStart, .batchStart, .batchEnd, .pause, .resume, .mappingChanged,
        .enabledChanged, .backgroundExpiration, .diagnosticUpload
    ]
    static func contains(_ operation: EventOperation, _ context: EventContext) -> Bool {
        operations.contains(operation) || context.diagnostic.map { stages.contains($0.stage) } == true
    }
}

public struct LogPage: Sendable {
    public let events: [DiagnosticEvent]
    public let nextBeforeSequence: Int64?
    public let prunedEventCount: Int64
    public let firstPrunedAt: Date?
}
public struct RunSummary: Codable, Sendable {
    public let id: UUID
    public let started: Date
    public let ended: Date?
    public let version: String
    public let revision: String
    public let outcome: String?
}
extension Ledger {
    /// Live progress stays in the engine; persist at most every five seconds per
    /// origin/resource, plus changed terminal samples. Failure is diagnostic-only:
    /// callers expose it through bounded OS/in-memory fallback, never fake Saved.
    public func appendProgress(context: EventContext, bytes: Int64, expectedBytes: Int64? = nil,
                               force: Bool = false) -> SafeFailure? {
        guard bytes >= 0, expectedBytes.map({ $0 >= bytes }) ?? true else {
            return SafeFailure(.invariant, domain: .core, cause: .invalidContract)
        }
        let key = context.origin.rawValue, now = ProcessInfo.processInfo.systemUptime
        if let old = progressSamples[key], old.resource == context.resourceID {
            if old.bytes == bytes || (!force && now - old.at < 5) { return nil }
        }
        progressSamples[key] = (now, context.resourceID, bytes)
        do {
            try appendEvent(.progress, context: context, decision: .proceed, bytes: bytes, expectedBytes: expectedBytes)
            return nil
        } catch {
            if case CoreError.persistence(let code) = error {
                return SafeFailure(.invariant, domain: .sqlite, code: Int(code), cause: .persistenceFailed)
            }
            return SafeFailure(.invariant, domain: .sqlite, cause: .persistenceFailed)
        }
    }
    /// Inserted inside callers' state transaction. Priority events outlive routine
    /// bursts, subject to the same hard diagnostic size/age limits.
    func record(_ operation: EventOperation, context: EventContext = EventContext(),
                severity: EventSeverity = .info, decision: EventDecision,
                from: JobState? = nil, to: JobState? = nil, failure: SafeFailure? = nil,
                duration: TimeInterval? = nil, bytes: Int64? = nil, expectedBytes: Int64? = nil,
                critical: Bool? = nil) throws {
        let date = Date()
        // Reuse the existing integer column: routine=0, milestones=1,
        // lifecycle/errors=2. No media/queue schema or acceptance policy changes.
        let priority: Int64 = critical == false ? 0 :
            (failure != nil || severity != .info || DiagnosticTimeline.contains(operation, context) ? 2 :
                (critical == true || [.confirmation, .attemptStart, .explicitRetry, .exhausted, .databaseFailure].contains(operation) ? 1 : 0))
        try db.execute("INSERT INTO events(occurred,origin,severity,run_id,critical,size,body) VALUES(?,?,?,?,?,0,?)", [date.sql, .text(context.origin.rawValue), .text(severity.rawValue), context.runID?.sql ?? .null, .integer(priority), .blob(Data())])
        let sequence = db.lastID
        let event = DiagnosticEvent(sequence: sequence, timestamp: date, version: version, revision: revision,
                                    context: context, operation: operation, severity: severity, decision: decision,
                                    fromState: from?.rawValue, toState: to?.rawValue, failure: failure,
                                    duration: duration, bytes: bytes, expectedBytes: expectedBytes)
        let data = try JSONEncoder().encode(event)
        try db.execute("UPDATE events SET body=?,size=? WHERE seq=?", [.blob(data), .integer(Int64(data.count)), .integer(sequence)])
        try db.execute("UPDATE log_budget SET byte_used=byte_used+? WHERE id=1", [.integer(Int64(data.count))])
        // Enforce a bounded page inside the same transaction even for callers
        // that only emit critical events; no observer recursion or nested BEGIN.
        _ = try pruneEventPage(now: date, byteBudget: 10 * 1024 * 1024, age: 7 * 86_400)
    }
    public func appendEvent(_ operation: EventOperation, context: EventContext, decision: EventDecision,
                            severity: EventSeverity = .info, failure: SafeFailure? = nil,
                            duration: TimeInterval? = nil, bytes: Int64? = nil, expectedBytes: Int64? = nil) throws {
        guard bytes.map({ $0 >= 0 }) ?? true, expectedBytes.map({ $0 >= 0 }) ?? true else { throw CoreError.invalidContract }
        try transaction {
            try record(operation, context: context, severity: severity, decision: decision, failure: failure,
                       duration: duration, bytes: bytes, expectedBytes: expectedBytes,
                       critical: nil)
        }
    }
    public func beginRun() throws -> UUID {
        let id = UUID()
        try transaction {
            try db.execute("INSERT INTO runs(id,started,version,revision) VALUES(?,?,?,?)", [id.sql, Date().sql, .text(version), .text(revision)])
            try record(.batchStart, context: EventContext(runID: id), decision: .proceed)
        }
        return id
    }
    public func endRun(_ id: UUID, needsAttention: Bool) throws {
        try transaction {
            try db.execute("UPDATE runs SET ended=?,outcome=? WHERE id=?", [Date().sql, .text(needsAttention ? "needsAttention" : "readyWorkDrained"), id.sql])
            try record(.batchEnd, context: EventContext(runID: id), decision: needsAttention ? .wait : .proceed)
        }
    }
    public func logPage(beforeSequence: Int64? = nil, origin: EventOrigin? = nil,
                        severity: EventSeverity? = nil, runID: UUID? = nil, limit: Int = 100,
                        origins: [EventOrigin]? = nil, reportFocus: DiagnosticReportFocus? = nil) throws -> LogPage {
        guard (1...200).contains(limit) else { throw CoreError.invalidContract }
        var clauses = ["seq < ?"]
        var values: [SQLValue] = [.integer(beforeSequence ?? Int64.max)]
        if let origin { clauses.append("origin=?"); values.append(.text(origin.rawValue)) }
        if let origins {
            guard origin == nil, !origins.isEmpty, origins.count <= 4,
                  Set(origins.map(\.rawValue)).count == origins.count else { throw CoreError.invalidContract }
            clauses.append("origin IN (\(origins.map { _ in "?" }.joined(separator: ",")))")
            values.append(contentsOf: origins.map { .text($0.rawValue) })
        }
        if let severity { clauses.append("severity=?"); values.append(.text(severity.rawValue)) }
        if let runID { clauses.append("run_id=?"); values.append(runID.sql) }
        if let reportFocus {
            switch reportFocus {
            case .failures:
                clauses.append("severity IN ('warning','error')")
            case .lifecycle:
                // Cast the JSON blob to text explicitly. Selection is independent
                // of historical critical flags and cannot be displaced by native
                // success/progress bursts. Bound decoding with the normal page cap.
                let operations = DiagnosticTimeline.operations.map(\.rawValue)
                let stages = DiagnosticTimeline.stages.map(\.rawValue)
                clauses.append("(json_extract(CAST(body AS TEXT),'$.operation') IN (\(operations.map { _ in "?" }.joined(separator: ","))) OR json_extract(CAST(body AS TEXT),'$.context.diagnostic.stage') IN (\(stages.map { _ in "?" }.joined(separator: ","))))")
                values.append(contentsOf: operations.map(SQLValue.text))
                values.append(contentsOf: stages.map(SQLValue.text))
            }
        }
        values.append(.integer(Int64(limit)))
        let events = try db.rows("SELECT body FROM events WHERE \(clauses.joined(separator: " AND ")) ORDER BY seq DESC LIMIT ?", values).map { try db.decode(DiagnosticEvent.self, $0, "body") }
        let budget = try db.rows("SELECT * FROM log_budget WHERE id=1").first!
        return LogPage(events: events, nextBeforeSequence: events.last?.sequence, prunedEventCount: budget.int("pruned"), firstPrunedAt: budget.double("first_pruned").map(Date.init(timeIntervalSince1970:)))
    }
    /// Diagnostic history only. Durable receipts, attempt counts, current failures
    /// and uncertain checkpoints remain in their separate tables.
    @discardableResult public func pruneDiagnostics(now: Date = Date(), byteBudget: Int64 = 10 * 1024 * 1024,
                                                    age: TimeInterval = 7 * 86_400) throws -> Int {
        guard byteBudget > 0, age > 0 else { throw CoreError.invalidContract }
        return try transaction { try pruneEventPage(now: now, byteBudget: byteBudget, age: age) }
    }
    private func pruneEventPage(now: Date, byteBudget: Int64, age: TimeInterval) throws -> Int {
        var size = try db.rows("SELECT byte_used AS n FROM log_budget WHERE id=1").first!.int("n")
        let cutoff = now.timeIntervalSince1970 - age
        let oldestDate = try db.rows("SELECT occurred FROM events ORDER BY seq LIMIT 1").first?.double("occurred")
        guard size > byteBudget || oldestDate.map({ $0 < cutoff }) == true else { return 0 }
        var deleted = 0
        func remove(_ row: SQLRow) throws {
            try db.execute("DELETE FROM events WHERE seq=?", [.integer(row.int("seq"))])
            size -= row.int("size"); deleted += 1
        }
        // Expired prefix first; then routine events; only then oldest priority
        // events if the hard budget still requires it. At most 200 deletions per
        // transaction. Receipt/attempt/failure tables are never part of rotation.
        let oldest = try db.rows("SELECT seq,size,occurred FROM events ORDER BY seq LIMIT 200")
        for row in oldest {
            guard (row.double("occurred") ?? 0) < cutoff else { break }
            try remove(row)
        }
        if size > byteBudget, deleted < 200 {
            let routine = try db.rows("SELECT seq,size FROM events WHERE critical=0 ORDER BY seq LIMIT ?", [.integer(Int64(200 - deleted))])
            for row in routine where size > byteBudget { try remove(row) }
        }
        if size > byteBudget, deleted < 200 {
            let milestones = try db.rows("SELECT seq,size FROM events WHERE critical=1 ORDER BY seq LIMIT ?", [.integer(Int64(200 - deleted))])
            for row in milestones where size > byteBudget { try remove(row) }
        }
        if size > byteBudget, deleted < 200 {
            let priority = try db.rows("SELECT seq,size FROM events ORDER BY seq LIMIT ?", [.integer(Int64(200 - deleted))])
            for row in priority where size > byteBudget { try remove(row) }
        }
        if deleted > 0 {
            try db.execute("UPDATE log_budget SET byte_used=?,pruned=pruned+?,first_pruned=COALESCE(first_pruned,?) WHERE id=1", [.integer(max(0, size)), .integer(Int64(deleted)), now.sql])
        }
        return deleted
    }
    public func runPage(before: Date? = nil, limit: Int = 100) throws -> [RunSummary] {
        guard (1...200).contains(limit) else { throw CoreError.invalidContract }
        return try db.rows("SELECT * FROM runs WHERE started<? ORDER BY started DESC LIMIT ?", [(before ?? .distantFuture).sql, .integer(Int64(limit))]).map { row in
            guard let id = UUID(uuidString: try row.string("id")), let started = row.double("started") else { throw CoreError.invalidContract }
            return RunSummary(id: id, started: Date(timeIntervalSince1970: started), ended: row.double("ended").map(Date.init(timeIntervalSince1970:)), version: try row.string("version"), revision: try row.string("revision"), outcome: try? row.string("outcome"))
        }
    }
    /// Stream redacted JSONL, never build an entire log export in Data. Only the
    /// whitelisted events/run summaries are exported, not asset tables or receipts.
    /// Caller supplies an app-owned export URL and handles sharing/deletion in P5.
    public func exportDiagnostics(to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw CoreError.invalidContract }
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes) else { throw CoreError.persistence(-1) }
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let budget = try db.rows("SELECT * FROM log_budget WHERE id=1").first!
        struct Header: Encodable {
            let format: Int; let version: String; let revision: String; let prunedEvents: Int64
            let captureComplete: Bool; let coverage: String; let diagnosticByteBudget: Int64; let diagnosticDays: Int
        }
        try file.write(contentsOf: encoder.encode(Header(format: 1, version: version, revision: revision,
            prunedEvents: budget.int("pruned"), captureComplete: budget.int("pruned") == 0,
            coverage: "Only emitted operations are observed; device and adapter coverage require separate verification. Receipts, attempts and current failures remain in separate ledger tables. Diagnostic events have bounded size/age retention.",
            diagnosticByteBudget: 10 * 1024 * 1024, diagnosticDays: 7)) + Data([10]))
        var cursor: Int64 = 0
        while true {
            let rows = try db.rows("SELECT seq,body FROM events WHERE seq>? ORDER BY seq LIMIT 100", [.integer(cursor)])
            if rows.isEmpty { break }
            for row in rows { try file.write(contentsOf: row.data("body") + Data([10])); cursor = row.int("seq") }
        }
        var runCursor = Date.distantFuture
        while true {
            let runs = try runPage(before: runCursor)
            if runs.isEmpty { break }
            for run in runs { try file.write(contentsOf: encoder.encode(run) + Data([10])) }
            runCursor = runs.last!.started
        }
        try file.synchronize()
    }
}
