import Foundation
import CloudifiedCore

private actor LaneBarrier {
    var entered: Set<Provider> = []
    var waiter: CheckedContinuation<Void, Never>?
    func join(_ provider: Provider) async {
        entered.insert(provider)
        if entered.count == 2 { waiter?.resume(); waiter = nil; return }
        await withCheckedContinuation { waiter = $0 }
    }
}
private actor LaneBoundary: ProviderAdapter {
    nonisolated let provider: Provider
    let unknown: String, failed: String
    let barrier: LaneBarrier
    var uploads = 0
    init(_ provider: Provider, tags: [String], barrier: LaneBarrier) {
        self.provider = provider; unknown = tags[0]; failed = tags[1]; self.barrier = barrier
    }
    func inspect(destination: Destination, resource: ResourceRequirement) -> RemotePresence {
        resource.tag == unknown ? .unknown(SafeFailure(.reconciliation, domain: provider == .google ? .google : .tdlib, cause: .outcomeUnknown)) : .verifiedAbsent
    }
    func upload(job: JobRecord, resource: ResourceRequirement, files: [LeasedFile], transferID: UUID,
                progress: @escaping @Sendable (TransferProgress) async -> Void) async -> UploadOutcome {
        uploads += 1
        if resource.tag == failed {
            await barrier.join(provider) // A sequential provider drain would hang this check.
            return .failed(UploadFailure(SafeFailure(.unsupportedOriginal, domain: .fileSystem, cause: .formatRejected), disposition: .permanent, acceptance: .definitelyNotAccepted), .terminal)
        }
        return .confirmed(RemoteReceipt(destinationID: job.destination.id, tag: resource.tag, opaqueReference: Data([1]), kind: .uploaded), .terminal)
    }
}
private struct LanePreparer: OriginalPreparer {
    let files: FileLeaseStore
    let ids: [UUID: UUID]
    func prepare(job: JobRecord, resource: ResourceRequirement, receipts: [RemoteReceipt]) async throws -> [LeasedFile] {
        [try await files.acquire(fileID: ids[resource.id]!)]
    }
}
func laneChecks(root: URL) async throws {
    let ledger = try Ledger(databaseURL: root.appendingPathComponent(UUID().uuidString), version: "offline", revision: "unknown")
    var destinations: [Destination] = []
    for provider in Provider.allCases {
        let d = try await ledger.selectDestination(Destination(provider: provider, verifiedFingerprint: String(repeating: "a", count: 64)))
        try await ledger.completeDestinationRecovery(d.id); destinations.append(d)
    }
    let scan = try await ledger.beginScan()
    let assets = try await ledger.registerAssets((0..<3).map { AssetIdentity(localIdentifier: "host-lane-\($0)", generation: String(repeating: "a", count: 64), kind: $0 == 2 ? .video : .photo) }, scanID: scan)
    try await ledger.completeScan(scan)
    let files = try FileLeaseStore(root: root.appendingPathComponent("lanes"), ledger: ledger)
    var ids: [UUID: UUID] = [:], tags: [String] = []
    for (i, asset) in assets.enumerated() {
        let role: ResourceRole = i == 2 ? .video : .still
        let content = OriginalContent(sha256: String(repeating: ["b", "d", "f"][i], count: 64), sha1: String(repeating: "c", count: 40), byteCount: 3, role: role)
        let resource = try ContentIdentity.resource(role: role, originals: [content]); tags.append(resource.tag)
        let plan = try ContentIdentity.plan(policyVersion: "host-lane", resources: [resource])
        for d in destinations { _ = try await ledger.enqueue(assetID: asset.id, destinationID: d.id, plan: plan) }
        let id = UUID(), reserve = try await ledger.reserveStorage(bytes: 3, availableBytes: 2_000_000_000, transportOverhead: 0)
        let ownership = try await files.beginExport(fileID: id)
        try Data([1, 2, 3]).write(to: ownership.publishedURL)
        let leased = try await files.registerPublished(fileID: id, byteCount: 3, reservationID: reserve.id, reexportable: true)
        try await files.endExport(ownership); try await files.release(leased); ids[resource.id] = id
    }
    let barrier = LaneBarrier()
    let adapters = Provider.allCases.map { LaneBoundary($0, tags: tags, barrier: barrier) }
    let engine = BackupEngine(ledger: ledger, files: files)
    let results = try await engine.runReadyBatch(adapters: adapters, preparer: LanePreparer(files: files, ids: ids))
    check(results.count == 2 && results.allSatisfy { $0.failure == nil }, "item error escaped into destination result")
    for provider in try await ledger.snapshot().providers {
        check(provider.photos?.waiting == 1 && provider.photos?.failed == 1 && provider.videos?.confirmed == 1, "bad photo blocked later video or crossed destination scope")
    }
    check(await barrier.entered.count == 2, "providers did not overlap")
    print("PASS actual engine: concurrent Google/Telegram, item inspection/upload failures isolated, healthy video confirms independently")
}
