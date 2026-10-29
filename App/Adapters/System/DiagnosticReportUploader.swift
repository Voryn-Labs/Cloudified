import Foundation
import CloudifiedCore

struct DiagnosticReportMetadata: Codable, Sendable {
    let version: String
    let build: String
    let revision: String
    let osMajor: Int
    let osMinor: Int
    let osPatch: Int
    let providerClientsAvailable: Bool
    let googleCredentialAvailable: Bool
    let network: DiagnosticDetail
    var backgroundConfiguration: DiagnosticBackgroundConfiguration? = nil
}
struct DiagnosticBackgroundConfiguration: Codable, Sendable {
    let continuationState: String
    let queuedSeconds: Int?
    let permittedIdentifierCount: Int
    let matchesSignedBundle: Bool
    let backgroundRefreshAvailable: Bool
}
struct DiagnosticReportFallback: Codable, Sendable {
    let timestamp: Date
    let failure: SafeFailure
}

/// Explicit user action only. One bounded public text report; no credentials or
/// raw account/service data are accepted by this interface. No automatic retries.
actor DiagnosticReportUploader {
    private var busy = false
    private let byteLimit = 256 * 1024
    private var lastRequestCompleted: TimeInterval?
    func upload(ledger: Ledger?, metadata: DiagnosticReportMetadata,
                fallback: [DiagnosticReportFallback],
                responseObserved: @Sendable (Int, Int, Int, DiagnosticReportRejection?) async -> Void) async throws -> URL {
        guard !busy else { throw CoreError.invalidTransition }
        busy = true; defer { busy = false }
        let body = try await buildReport(ledger: ledger, metadata: metadata, fallback: fallback)
        var request = URLRequest(url: URL(string: "https://dpaste.com/api/v2/")!)
        request.httpMethod = "POST"; request.httpBody = Self.formBody(body); request.timeoutInterval = 30
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("Cloudified/\(metadata.version) (https://github.com/Voryn-Labs/Cloudified)", forHTTPHeaderField: "User-Agent")
        let transport = ForegroundFileUploadTransport()
        let (data, response) = try await requestData(request, transport: transport)
        guard let http = response as? HTTPURLResponse else { throw SafeFailure(.transfer, domain: .urlSession, cause: .formatRejected) }
        await responseObserved(http.statusCode, data.count, request.httpBody?.count ?? 0,
            http.statusCode == 201 ? nil : Self.rejection(http.statusCode, data))
        // A partial response, redirect or uncertain result is never success.
        guard http.statusCode == 201 else {
            throw SafeFailure(.transfer, domain: .urlSession, code: http.statusCode, cause: .providerRejected)
        }
        guard data.count <= 256, let raw = String(data: data, encoding: .utf8),
              let returned = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              returned.scheme == "https", returned.host == "dpaste.com", returned.port == nil,
              returned.user == nil, returned.password == nil, returned.query == nil, returned.fragment == nil,
              returned.path.hasPrefix("/"), returned.path.split(separator: "/").count == 1 else {
            throw SafeFailure(.transfer, domain: .urlSession, cause: .formatRejected)
        }
        let id = returned.path.split(separator: "/")[0]
        guard (1...64).contains(id.utf8.count), id.utf8.allSatisfy({ Self.isAlphanumeric($0) }) else {
            throw SafeFailure(.transfer, domain: .urlSession, cause: .formatRejected)
        }
        let url = URL(string: "https://dpaste.com/\(id)")!
        var verify = URLRequest(url: URL(string: "https://dpaste.com/\(id).txt")!)
        verify.timeoutInterval = 30
        verify.setValue("Cloudified/\(metadata.version) (https://github.com/Voryn-Labs/Cloudified)", forHTTPHeaderField: "User-Agent")
        let (stored, verificationResponse) = try await requestData(verify, transport: transport)
        guard let verificationHTTP = verificationResponse as? HTTPURLResponse else {
            throw SafeFailure(.transfer, domain: .urlSession, cause: .formatRejected)
        }
        await responseObserved(verificationHTTP.statusCode, stored.count, 0,
            verificationHTTP.statusCode == 200 ? nil : Self.rejection(verificationHTTP.statusCode, stored))
        guard verificationHTTP.statusCode == 200 else {
            throw SafeFailure(.transfer, domain: .urlSession, code: verificationHTTP.statusCode, cause: .providerRejected)
        }
        // HTTP success alone does not establish completeness. Verify raw content.
        guard stored == body else { throw SafeFailure(.transfer, domain: .urlSession, cause: .formatRejected) }
        return url
    }
    /// Pure bounded report construction, separately inspectable without a public
    /// upload. Uses the same redacted event types as the full diagnostic export.
    func buildReport(ledger: Ledger?, metadata: DiagnosticReportMetadata,
                     fallback: [DiagnosticReportFallback]) async throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        struct SectionCoverage: Encodable {
            let section: String
            let includedEvents: Int
            let pagesRead: Int
            let limited: Bool
            let oldestSequence: Int64?
            let newestSequence: Int64?
        }
        var lines: [(sequence: Int64, data: Data)] = []
        var seen: Set<Int64> = []
        var sections: [SectionCoverage] = []
        var ledgerReadFailure: SafeFailure?
        var asOfSequence: Int64?
        var prunedEvents: Int64 = 0
        var truncated = ledger == nil
        struct ProviderFacts: Encodable {
            let provider: Provider
            let enabled: Bool
            let recoveryComplete: Bool
            let total: Int?
            let saved: Int?
            let waiting: Int?
            let failed: Int?
            let retained: Int
            let protectedUnresolved: Int
        }
        struct QueueFacts: Encodable {
            let capturedAt: Date
            let scanned: Bool
            let total: Int?
            let savedToBoth: Int?
            let providers: [ProviderFacts]
            let computedSnapshots: UInt64
            let reusedSnapshots: UInt64
        }
        var queue: QueueFacts?
        var jobEvidence = Data()
        // Separate SQL selections reserve space for lifecycle/errors even after
        // thousands of routine successes. Freeze an upper sequence boundary;
        // deduplicate overlaps and disclose every cap instead of claiming a full
        // capture. Decoded pages and encoded report storage are strictly bounded.
        let selections: [(String, DiagnosticReportFocus?, EventOrigin?, Int, Int)] = [
            ("rootCauses", .rootCauses, nil, 32 * 1024, 2),
            ("lifecycle", .lifecycle, nil, 48 * 1024, 2),
            ("failures", .failures, nil, 32 * 1024, 2),
            ("googleRecent", nil, .google, 40 * 1024, 3),
            ("telegramRecent", nil, .telegram, 24 * 1024, 2),
            ("recent", nil, nil, 24 * 1024, 2)
        ]
        if let ledger {
            do {
                do {
                    jobEvidence = try await ledger.diagnosticStateJSONL(limit: 12, byteBudget: 24 * 1024)
                    if let footer = jobEvidence.split(separator: 10).last,
                       let coverage = try JSONSerialization.jsonObject(with: Data(footer)) as? [String: Any] {
                        truncated = truncated || coverage["byteLimited"] as? Bool == true ||
                            ["omittedJobs", "unreadableJobs", "unreadableCheckpointGroups"].contains { (coverage[$0] as? Int ?? 0) > 0 }
                    }
                }
                catch { ledgerReadFailure = ProviderSupport.safe(error, domain: .sqlite); truncated = true }
                let snapshot = try await ledger.snapshot()
                let performance = await ledger.snapshotPerformance()
                queue = QueueFacts(capturedAt: Date(), scanned: snapshot.scanned,
                    total: snapshot.libraryTotal, savedToBoth: snapshot.savedToBoth,
                    providers: snapshot.providers.map { p in
                        ProviderFacts(provider: p.provider, enabled: p.enabled, recoveryComplete: p.recoveryComplete,
                            total: p.total, saved: p.confirmed,
                            waiting: p.photos.flatMap { a in p.videos.map { a.waiting + $0.waiting } },
                            failed: p.photos.flatMap { a in p.videos.map { a.failed + $0.failed } },
                            retained: p.retainedTransfers, protectedUnresolved: p.protectedUnresolvedTransfers)
                    }, computedSnapshots: performance.computed, reusedSnapshots: performance.reused)
                let latest = try await ledger.logPage(limit: 1)
                asOfSequence = latest.events.first?.sequence
                prunedEvents = latest.prunedEventCount
                let upper = asOfSequence.map { $0 == Int64.max ? $0 : $0 + 1 } ?? 1
                for (name, focus, origin, budget, pageLimit) in selections {
                    var cursor: Int64? = upper
                    var bytes = 0, pages = 0
                    var included: [Int64] = []
                    var limited = false
                    do {
                        for pageIndex in 0..<pageLimit {
                            try Task.checkCancellation()
                            let page = try await ledger.logPage(beforeSequence: cursor, origin: origin, limit: 200, reportFocus: focus)
                            pages += 1; prunedEvents = max(prunedEvents, page.prunedEventCount)
                            for event in page.events where !seen.contains(event.sequence) {
                                let line = try encoder.encode(event) + Data([10])
                                guard bytes + line.count <= budget else { limited = true; break }
                                lines.append((event.sequence, line)); seen.insert(event.sequence)
                                included.append(event.sequence); bytes += line.count
                            }
                            if limited || page.events.count < 200 { break }
                            cursor = page.nextBeforeSequence
                            if pageIndex == pageLimit - 1 { limited = true }
                        }
                    } catch is CancellationError { throw CancellationError() }
                    catch { ledgerReadFailure = ProviderSupport.safe(error, domain: .sqlite); limited = true }
                    sections.append(SectionCoverage(section: name, includedEvents: included.count,
                        pagesRead: pages, limited: limited, oldestSequence: included.min(), newestSequence: included.max()))
                    truncated = truncated || limited
                    if ledgerReadFailure != nil { break }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { ledgerReadFailure = ProviderSupport.safe(error, domain: .sqlite); truncated = true }
        }
        struct Header: Encodable {
            let format: Int
            let metadata: DiagnosticReportMetadata
            let selectedEvents: Int
            let asOfSequence: Int64?
            let sections: [SectionCoverage]
            let prunedEvents: Int64
            let truncated: Bool
            let coverage: String
            let ledgerUnavailable: Bool
            let ledgerReadFailure: SafeFailure?
            let fallback: [DiagnosticReportFallback]
            let queue: QueueFacts?
        }
        var body = try encoder.encode(Header(format: 4, metadata: metadata,
            selectedEvents: lines.count, asOfSequence: asOfSequence, sections: sections,
            prunedEvents: prunedEvents, truncated: truncated || prunedEvents > 0,
            coverage: "Selected lifecycle, failure, separate provider and recent events; not a complete capture. Section caps and prior pruning may omit events.",
            ledgerUnavailable: ledger == nil, ledgerReadFailure: ledgerReadFailure,
            fallback: Array(fallback.suffix(50)), queue: queue)) + Data([10])
        body.append(jobEvidence)
        for line in lines.sorted(by: { $0.sequence > $1.sequence }) { body.append(line.data) }
        guard body.count <= byteLimit else { throw CoreError.invalidContract }
        try Task.checkCancellation()
        return body
    }
    /// Interpret only short exact service errors. Never persist arbitrary body
    /// text, echoed report contents, account data, HTML, or a guessed diagnosis.
    private static func rejection(_ status: Int, _ data: Data) -> DiagnosticReportRejection {
        if status == 413 { return .contentTooLarge }
        if status == 429 { return .rateLimited }
        guard data.count <= 256, let raw = String(data: data, encoding: .utf8) else { return .unknown }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "content too large", "content too large.", "paste too large", "paste too large.", "content too long", "content too long.": return .contentTooLarge
        case "invalid expiry_days", "invalid expiry_days.": return .invalidExpiry
        case "rate limit exceeded", "too many requests": return .rateLimited
        case "bad request", "bad request.", "invalid request", "invalid request.": return .invalidRequest
        default: return .unknown
        }
    }
    private func requestData(_ request: URLRequest, transport: ForegroundFileUploadTransport) async throws -> (Data, URLResponse) {
        // dpaste permits one request/second. Space even verification reads and
        // successive explicit taps; never automatically retry a rejected POST.
        if let lastRequestCompleted {
            let remaining = 1.1 - (ProcessInfo.processInfo.systemUptime - lastRequestCompleted)
            if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        }
        try Task.checkCancellation()
        defer { lastRequestCompleted = ProcessInfo.processInfo.systemUptime }
        return try await transport.requestData(request)
    }
    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
    private static func formBody(_ body: Data) -> Data {
        let hex = Array("0123456789ABCDEF".utf8)
        var form = Data("content=".utf8); form.reserveCapacity(body.count * 3 + 16)
        for byte in body {
            if isAlphanumeric(byte) || [42, 45, 46, 95].contains(byte) { form.append(byte) }
            else if byte == 32 { form.append(43) }
            else { form.append(37); form.append(hex[Int(byte >> 4)]); form.append(hex[Int(byte & 15)]) }
        }
        form.append(Data("&expiry_days=7".utf8)); return form
    }
}
