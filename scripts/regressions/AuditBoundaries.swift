import Foundation
@testable import CloudifiedCore

// Only native/network boundaries are substituted; checked code comes from App.
typealias PHAssetResourceDataRequestID = Int32
struct PHAssetResourceManager {
    static func `default`() -> PHAssetResourceManager { .init() }
    func cancelDataRequest(_ id: Int32) {}
}
struct FileUploadResult: Sendable { let data: Data; let response: HTTPURLResponse }
protocol FileUploadTransport: Sendable {
    var continuesAfterProcessExit: Bool { get }
    func upload(_ request: URLRequest, fromFile file: URL, transferID: UUID,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> FileUploadResult
    func cancel(transferID: UUID) async
    func forget(transferID: UUID) async
}
struct GPMCError: Error {
    enum Kind { case malformed, transport, server(Int), credentialRejected, storageFull }
    var kind: Kind = .malformed
    let message: String
    var status: GoogleStatus? = nil
    var retryAfter: Date? = nil
    var transportFailure: SafeFailure? = nil
    var googleReason: DiagnosticGoogleError? = nil
    var httpStatus: Int? = nil
    var responseBytes: Int? = nil
    var responseKind: DiagnosticResponseKind? = nil
    var commitNotSubmitted = false
    var diagnosticStage: DiagnosticStage? = nil
}
private actor ControlBarrier {
    var first: CheckedContinuation<Void, Never>?
    var count = 0
    func join() async {
        count += 1
        if count % 2 == 0 { first?.resume(); first = nil }
        else { await withCheckedContinuation { first = $0 } }
    }
}
private final class ControlProtocol: URLProtocol, @unchecked Sendable {
    static let barrier = ControlBarrier()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task {
            await Self.barrier.join()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data([1]))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
private final class MetadataPageProtocol: URLProtocol, @unchecked Sendable {
    static let payload = Data(repeating: 1, count: 2_097_152)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private actor CancelBoundary: ProviderAdapter {
    nonisolated let provider = Provider.google
    var entered = false
    func inspect(destination: Destination, resource: ResourceRequirement) -> RemotePresence { .verifiedAbsent }
    func upload(job: JobRecord, resource: ResourceRequirement, files: [LeasedFile], transferID: UUID,
                progress: @escaping @Sendable (TransferProgress) async -> Void) async -> UploadOutcome {
        entered = true
        do { try await Task.sleep(for: .seconds(3600)); preconditionFailure("cancel boundary was never cancelled") }
        catch {
            return .failed(UploadFailure(SafeFailure(.connectivity, domain: .google, cause: .interrupted),
                disposition: .waiting, acceptance: .unknown), .retainedByTransport)
        }
    }
}
private struct CancelPreparer: OriginalPreparer {
    let store: FileLeaseStore; let id: UUID
    func prepare(job: JobRecord, resource: ResourceRequirement, receipts: [RemoteReceipt]) async throws -> [LeasedFile] {
        [try await store.acquire(fileID: id)]
    }
}
func auditBoundaryChecks(root: URL) async throws {
    let sql = try SQLite(url: root.appendingPathComponent("audit.sqlite"))
    let text = try sql.rows("SELECT CAST(X'610062' AS TEXT) AS value").first!.string("value")
    check(text == "a\0b", "SQLite text truncated at embedded NUL")
    print("PASS actual SQLite text: full UTF-8 byte length preserves embedded NUL; statements remain scoped")

    let f = try await fixture(root), store = try FileLeaseStore(root: root.appendingPathComponent("audit-leases"), ledger: f.ledger)
    let reservation = try await f.ledger.reserveStorage(bytes: 3, availableBytes: 2_000_000_000, transportOverhead: 0)
    let ownership = try await store.beginExport(fileID: UUID())
    try Data([1,2,3]).write(to: ownership.partialURL)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: ownership.partialURL.path)
    do { try await store.rollbackExport(ownership, reservationID: reservation.id); preconditionFailure("locked rollback unexpectedly succeeded") }
    catch { }
    await store.completeStartupInventory()
    let healthy = store.root.appendingPathComponent(UUID().uuidString + ".partial")
    try Data([1]).write(to: healthy)
    check(try await store.reclaimOrphans(limit: 20) == 1, "locked orphan blocked healthy successor")
    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: ownership.partialURL.path)
    check(try await store.reclaimOrphans(limit: 20) == 1, "failed rollback stranded in-memory export pin")
    try await f.ledger.releaseReservation(reservation.id)
    print("PASS actual rollback/orphan cleanup: failed unlink drops terminal writer pin; locked orphan does not starve other files")

    let coalescer = SourceProgressCoalescer(ledger: f.ledger, context: EventContext(origin: .source))
    try coalescer.update(bytes: 10)
    do { try await coalescer.finish(finalBytes: 9); preconditionFailure("nonmonotonic terminal bytes accepted") }
    catch { }
    check(coalescer.closedForBoundary(), "invalid final sample left consumer stream open")
    print("PASS actual progress coalescer: invalid final sample still closes and joins consumer")

    let file = root.appendingPathComponent("audit-photo-export")
    let export = ExportRequest(writer: try StreamingFileWriter(fileURL: file))
    let cancelled = Task {
        try await withCheckedThrowingContinuation { continuation in
            check(export.begin(continuation), "export did not begin")
            export.receive(Data([1,2,3])); export.cancel(); export.install(1)
        }
    }
    do { _ = try await cancelled.value; preconditionFailure("cancelled export returned success") }
    catch is CancellationError { }
    export.receive(Data([4,5])); export.complete(nil)
    check(try Data(contentsOf: file) == Data([1,2,3]), "late PhotoKit data wrote after cancel")
    let stalled = ExportRequest(writer: try StreamingFileWriter(fileURL: root.appendingPathComponent("audit-stalled")))
    do {
        _ = try await withCheckedThrowingContinuation { continuation in
            _ = stalled.begin(continuation); stalled.forceStallForBoundary()
        }
        preconditionFailure("stalled export returned success")
    } catch let failure as SafeFailure { check(failure.cause == .deadlineExceeded, "stall reason lost") }
    stalled.complete(nil)
    print("PASS actual PhotoKit writer fence: cancellation/stall resumes without native completion; late callbacks cannot write or resume twice")

    let video = root.appendingPathComponent("audit-video")
    try Data((0..<64).map(UInt8.init)).write(to: video)
    let split = try LosslessVideoPartSplitter.planSplit(fileURL: video, totalBytes: 64, targetPartSize: 24, chunkSize: 7)
    check(split.parts.map(\.byteCount) == [24,24,16], "split coverage differs")
    check(split.originalSha256 == (try StreamingFileHasher.hash(fileURL: video)).sha256, "default split recipe lacks original hash")
    var combined = Data()
    for part in split.parts {
        let path = root.appendingPathComponent("audit-part-\(part.partIndex)")
        _ = try LosslessVideoPartSplitter.extractPart(from: video, descriptor: part, to: path, chunkSize: 5)
        combined.append(try Data(contentsOf: path))
    }
    check(combined == Data((0..<64).map(UInt8.init)), "split changed original bytes")
    do { _ = try LosslessVideoPartSplitter.planSplit(fileURL: video, totalBytes: 64, targetPartSize: 64); preconditionFailure("invalid single-part recipe returned") }
    catch { }
    print("PASS actual video splitter: streamed parts reassemble byte-exactly; small input cannot return invalid split recipe")

    let receipt = PreparedUpload(uploadURL: URL(string: "https://photos.googleapis.com/fixture")!,
        hash: Data(repeating: 1, count: 20), filename: "fixture.heic", modified: Date(), byteCount: 3)
    do {
        _ = try await CommitSubmissionHarness(started: false).commit(receipt, useQuota: false, saver: false, phase: { _ in })
        preconditionFailure("pre-submit cancellation succeeded")
    } catch let error as GPMCError {
        check(error.commitNotSubmitted && error.transportFailure?.cause == .interrupted
              && error.diagnosticStage == .googleCommitNotSubmitted,
            "pre-submit cancellation lost its explicit no-request proof")
    }
    do {
        _ = try await CommitSubmissionHarness(started: true).commit(receipt, useQuota: false, saver: false, phase: { _ in })
        preconditionFailure("submitted cancellation succeeded")
    } catch is CancellationError {}
    print("PASS actual commit boundary: only current never-submitted cancellation clears uncertainty")

    let errorData = Proto.int(1, 13) + Proto.string(2, "PRIVATE RESPONSE MUST NOT ENTER PUBLIC DIAGNOSTICS")
    let httpError = HTTPURLResponse(url: URL(string: "https://boundary.invalid/commit")!, statusCode: 500, httpVersion: nil,
        headerFields: ["Content-Type": "application/x-protobuf"])!
    do { try HTTPFailureHarness().check(errorData, httpError); preconditionFailure("HTTP 500 accepted") }
    catch let error as GPMCError {
        check(error.httpStatus == 500 && error.status?.rawCode == 13 && error.responseBytes == errorData.count
            && error.responseKind == .protobuf, "Google rejection lost structured HTTP/RPC evidence")
    }
    let jsonError = Data(#"{"error":{"code":500,"status":"INTERNAL","message":"PRIVATE JSON MESSAGE"}}"#.utf8)
    do { try HTTPFailureHarness().check(jsonError, httpError); preconditionFailure("JSON HTTP 500 accepted") }
    catch let error as GPMCError {
        check(error.status?.rawCode == 13 && error.responseKind == .json, "structured JSON Google reason lost or mistaken for protobuf")
    }
    for invalid in [Data(), Proto.bytes(1, Proto.bytes(3, Proto.string(1, ""))), Proto.bytes(1, Proto.bytes(3, Proto.string(1, String(repeating: "x", count: 2049)))), Data([255])] {
        do { _ = try HTTPFailureHarness().mediaKey(invalid); preconditionFailure("invalid or empty key accepted as upload success") }
        catch let error as GPMCError {
            check(error.httpStatus == 200 && error.responseBytes == invalid.count
                && (!invalid.isEmpty || error.responseKind == .empty)
                && [.commitKeyMissing, .commitResponseInvalid].contains(error.googleReason), "unconfirmed HTTP 200 lost precise protocol failure evidence")
        }
    }
    check(try HTTPFailureHarness().mediaKey(Proto.bytes(1, Proto.bytes(3, Proto.string(1, "real-key")))) == "real-key", "valid confirmation key rejected")
    print("PASS actual HTTP error evidence: HTTP status, canonical Google code, response shape/size preserved without exporting raw message")

    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ControlProtocol.self]
    let control = ForegroundFileUploadTransport(configuration: config, reuseDataSession: true)
    let submission = GoogleCommitDispatch()
    let cancelledSubmission = GoogleCommitDispatch()
    let cancelledControl = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await control.requestData(URLRequest(url: URL(string: "https://boundary.invalid/cancelled")!),
            onStart: { cancelledSubmission.markSubmitted() })
    }
    do { _ = try await cancelledControl.value; preconditionFailure("cancelled request started") }
    catch is CancellationError {}
    check(!cancelledSubmission.submitted, "pre-start cancellation fabricated commit submission")
    async let first = control.requestData(URLRequest(url: URL(string: "https://boundary.invalid/one")!),
        onStart: { submission.markSubmitted() })
    async let second = control.requestData(URLRequest(url: URL(string: "https://boundary.invalid/two")!))
    let responses = try await (first, second)
    check(submission.submitted, "resumed control task did not fence ambiguous acceptance")
    check(responses.0.0 == Data([1]) && responses.1.0 == Data([1]), "overlapping control responses collided")
    print("PASS actual Google HTTP transport: concurrent control requests complete on one reused session without operation collisions")

    let metadataConfig = URLSessionConfiguration.ephemeral
    metadataConfig.protocolClasses = [MetadataPageProtocol.self]
    let metadataTransport = ForegroundFileUploadTransport(configuration: metadataConfig, reuseDataSession: true)
    let metadataRequest = URLRequest(url: URL(string: "https://boundary.invalid/library")!)
    do {
        _ = try await metadataTransport.requestData(metadataRequest)
        preconditionFailure("shared 1 MiB HTTP cap accepted an oversized metadata response")
    } catch let error as GPMCError {
        check(error.googleReason == .responseLimit, "old cap did not reproduce the safely classified failure")
    }
    let metadataResponse = try await metadataTransport.requestData(metadataRequest, responseLimit: 4_194_304)
    check(metadataResponse.0 == MetadataPageProtocol.payload, "dedicated metadata HTTP budget still rejects valid large response")
    print("PASS actual Google metadata HTTP: old 1 MiB rejection reproduced; dedicated 4 MiB succeeds without relaxing default controls")

    let liveID = UUID(), reserve = try await f.ledger.reserveStorage(bytes: 3, availableBytes: 2_000_000_000, transportOverhead: 0)
    let writer = try await store.beginExport(fileID: liveID)
    try Data([1,2,3]).write(to: writer.publishedURL)
    let lease = try await store.registerPublished(fileID: liveID, byteCount: 3, reservationID: reserve.id, reexportable: true)
    try await store.endExport(writer); try await store.release(lease)
    let engine = BackupEngine(ledger: f.ledger, files: store), adapter = CancelBoundary()
    let batch = Task { try await engine.runReadyBatch(adapters: [adapter], preparer: CancelPreparer(store: store, id: liveID)) }
    while await !adapter.entered { await Task.yield() }
    batch.cancel(); _ = try await batch.value
    let interruptions = try await f.ledger.logPage(origin: .google, limit: 100, reportFocus: .rootCauses)
    check(interruptions.events.contains { $0.context.diagnostic?.stage == .workerInterruption && $0.context.jobID == f.jobID
        && $0.context.diagnostic?.policyCause == .interrupted }, "cancelled worker lost job-linked cancellation cause")
    check(try await f.ledger.snapshot().providers.first { $0.provider == .google }?.retainedTransfers == 1, "parent cancellation released unresolved transport")
    print("PASS actual engine cancellation: cancelled batch joins worker while preserving unresolved native hold")
}
