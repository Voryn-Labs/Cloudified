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
    enum Kind { case malformed, transport }
    let kind: Kind
    let message: String
    var transportFailure: SafeFailure? = nil
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

    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ControlProtocol.self]
    let control = ForegroundFileUploadTransport(configuration: config, reuseDataSession: true)
    async let first = control.requestData(URLRequest(url: URL(string: "https://boundary.invalid/one")!))
    async let second = control.requestData(URLRequest(url: URL(string: "https://boundary.invalid/two")!))
    let responses = try await (first, second)
    check(responses.0.0 == Data([1]) && responses.1.0 == Data([1]), "overlapping control responses collided")
    print("PASS actual Google HTTP transport: concurrent control requests complete on one reused session without operation collisions")

    let liveID = UUID(), reserve = try await f.ledger.reserveStorage(bytes: 3, availableBytes: 2_000_000_000, transportOverhead: 0)
    let writer = try await store.beginExport(fileID: liveID)
    try Data([1,2,3]).write(to: writer.publishedURL)
    let lease = try await store.registerPublished(fileID: liveID, byteCount: 3, reservationID: reserve.id, reexportable: true)
    try await store.endExport(writer); try await store.release(lease)
    let engine = BackupEngine(ledger: f.ledger, files: store), adapter = CancelBoundary()
    let batch = Task { try await engine.runReadyBatch(adapters: [adapter], preparer: CancelPreparer(store: store, id: liveID)) }
    while await !adapter.entered { await Task.yield() }
    batch.cancel(); _ = try await batch.value
    check(try await f.ledger.snapshot().providers.first { $0.provider == .google }?.retainedTransfers == 1, "parent cancellation released unresolved transport")
    print("PASS actual engine cancellation: cancelled batch joins worker while preserving unresolved native hold")
}
