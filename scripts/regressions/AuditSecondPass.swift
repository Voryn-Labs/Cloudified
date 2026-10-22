import Foundation
import CloudifiedCore

// Offline protocol boundary: never opens a socket or contacts a cloud account.
final class OfflineUploadProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
private actor CallbackGate {
    var entered: Set<Provider> = []
    var releaseGoogle: CheckedContinuation<Void, Never>?
    var batchReturned = false, settled = false
    func callback(_ provider: Provider) async {
        entered.insert(provider)
        if provider == .google { await withCheckedContinuation { releaseGoogle = $0 } }
    }
    func release() { releaseGoogle?.resume(); releaseGoogle = nil }
    func returned() { batchReturned = true }
    func joined() { settled = true }
}
private struct EmptyLane: ProviderAdapter {
    let provider: Provider
    func inspect(destination: Destination, resource: ResourceRequirement) async -> RemotePresence { .verifiedAbsent }
    func upload(job: JobRecord, resource: ResourceRequirement, files: [LeasedFile], transferID: UUID,
                progress: @escaping @Sendable (TransferProgress) async -> Void) async -> UploadOutcome {
        preconditionFailure("empty callback fixture unexpectedly uploaded")
    }
}
private struct EmptyPreparer: OriginalPreparer {
    func prepare(job: JobRecord, resource: ResourceRequirement, receipts: [RemoteReceipt]) async throws -> [LeasedFile] { [] }
}
func secondPassChecks(root: URL) async throws {
    let ledger = try Ledger(databaseURL: root.appendingPathComponent(UUID().uuidString), version: "offline", revision: "unknown")
    for provider in Provider.allCases {
        let d = try await ledger.selectDestination(Destination(provider: provider, verifiedFingerprint: String(repeating: "1", count: 64)))
        try await ledger.completeDestinationRecovery(d.id)
    }
    let store = try FileLeaseStore(root: root.appendingPathComponent(UUID().uuidString), ledger: ledger)
    let engine = BackupEngine(ledger: ledger, files: store), gate = CallbackGate()
    let batch = Task {
        _ = try await engine.runReadyBatch(adapters: Provider.allCases.map { EmptyLane(provider: $0) }, preparer: EmptyPreparer()) {
            await gate.callback($0.provider)
        }
        await gate.returned()
    }
    while await gate.entered.count < 2 { await Task.yield() }
    let settle = Task { _ = await engine.settleProvider(.google); await gate.joined() }
    try await Task.sleep(for: .milliseconds(50))
    check(await !gate.batchReturned, "batch ended before Google callback completed")
    check(await !gate.settled, "settlement ignored callback still in flight")
    await gate.release(); try await batch.value; await settle.value
    check(await gate.batchReturned, "completed callbacks never released batch")
    print("PASS actual batch callbacks: other lane cannot tear down a suspended callback; account settlement joins it")

    let transport = try BackgroundFileUploadTransport(root: root.appendingPathComponent(UUID().uuidString))
    let old = UUID()
    if case .active = try transport.cachedInventory(old, new: true) {} else { preconditionFailure("new task absent from earlier inventory was discarded") }
    let detached = Task { try await transport.attachBoundaryWaiter(old) }
    while !transport.hasBoundaryWaiter(old) { await Task.yield() }
    if case .absent = try transport.cachedInventory(old, new: false) {} else { preconditionFailure("stale cached task stayed active without OS reader") }
    do { _ = try await detached.value; preconditionFailure("missing native task fabricated upload result") }
    catch let failure as SafeFailure { check(failure.cause == .interrupted, "missing native task left a waiter suspended") }
    let bad = UUID()
    _ = try transport.cachedInventory(bad, new: true)
    transport.forceFailure(bad); transport.completeFailure(bad)
    if case .failed = try transport.cachedInventory(bad, new: false) {} else { preconditionFailure("durable terminal journal stayed poisoned") }
    transport.forceFailure(UUID())
    let file = root.appendingPathComponent(UUID().uuidString)
    try Data([1,2,3]).write(to: file)
    let next = UUID(), request = URLRequest(url: URL(string: "https://photos.googleapis.com/offline")!)
    try transport.submit(request, fromFile: file, transferID: next)
    var terminal = false
    for _ in 0..<100 {
        if case .failed = try await transport.inventory(next) { terminal = true; break }
        try await Task.sleep(for: .milliseconds(10))
    }
    check(terminal, "unrelated journal failure blocked next native submission")
    try await transport.finishWhenIdle()
    print("PASS actual Google transport: stale/new OS snapshot boundary, per-ID errors, durable terminal recovery and unrelated submission; zero network")

    let exports = try DiagnosticExportStore(boundaryRoot: root.appendingPathComponent(UUID().uuidString))
    let exported = try await exports.export(ledger: ledger)
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: exported.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: exported.path) }
    do { try await exports.release(exported); preconditionFailure("locked export unexpectedly removed") } catch {}
    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: exported.path)
    try await exports.release(exported)
    check(!FileManager.default.fileExists(atPath: exported.path), "failed diagnostic unlink lost its retry ownership")
    print("PASS actual diagnostic export: failed unlink remains releasable without restart")

    for (seconds, expected, nanos) in [(-1.25, Int64(-2), UInt64(750_000_000)), (0.0, 0, 0), (1.5, 1, 500_000_000)] {
        let value = try CommitTimestampHarness.commitTimestamp(Date(timeIntervalSince1970: seconds))
        check(try Proto.number(1, in: value) == UInt64(bitPattern: expected), "timestamp seconds clamped or sign lost")
        check(try Proto.number(2, in: value) == nanos, "timestamp fraction fabricated")
    }
    do { _ = try CommitTimestampHarness.commitTimestamp(Date(timeIntervalSince1970: .nan)); preconditionFailure("nonfinite timestamp accepted") } catch {}
    print("PASS actual commit timestamp: pre-1970 signed seconds and fractions survive protobuf encoding; invalid dates rejected")

    let f = try await fixture(root, provider: .telegram), job = try await start(f)
    let scan = try await f.ledger.beginScan()
    let assets = try await f.ledger.registerAssets([f.asset, AssetIdentity(localIdentifier: "ready-after-failure", generation: String(repeating: "e", count: 64), kind: .photo)], scanID: scan)
    try await f.ledger.completeScan(scan)
    let resource = try ContentIdentity.resource(role: .still, originals: [OriginalContent(sha256: String(repeating: "f", count: 64), sha1: String(repeating: "e", count: 40), byteCount: 3, role: .still)])
    let healthy = try await f.ledger.enqueue(assetID: assets[1].id, destinationID: f.destination.id, plan: ContentIdentity.plan(policyVersion: "queue-tail", resources: [resource]))
    let failure = UploadFailure(SafeFailure(.transfer, domain: .tdlib, cause: .providerRejected), disposition: .retryable, acceptance: .definitelyNotAccepted)
    try await f.ledger.failAttempt(jobID: job.id, failure: failure, now: .now.addingTimeInterval(-300))
    check(try await f.ledger.claimNext(destinationID: f.destination.id, runID: UUID())?.id == healthy, "retry jumped ahead of ready original")
    try await f.ledger.confirm(RemoteReceipt(destinationID: f.destination.id, tag: resource.tag, opaqueReference: Data([1]), kind: .uploaded), jobID: healthy, resourceID: resource.id)
    for _ in 0..<2 {
        let retry = try await start(f)
        try await f.ledger.failAttempt(jobID: retry.id, failure: failure, now: .now.addingTimeInterval(-300))
    }
    let exhausted = try await f.ledger.job(job.id)
    check(exhausted.attempts == 3 && exhausted.state == .failed, "retry queue created an infinite cycle or exceeded cap")
    check(try await f.ledger.claimNext(destinationID: f.destination.id, runID: UUID()) == nil, "exhausted item automatically requeued")
    print("PASS actual retry queue: ready files precede retried item, three TOTAL send attempts, exhaustion remains visible and unclaimed")
}
