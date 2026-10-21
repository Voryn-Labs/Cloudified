import Foundation
@testable import CloudifiedCore

actor QueueInventoryBoundary {
    nonisolated let continuesAfterProcessExit = true
    enum Inventory: Sendable { case active, absent, completed(FileUploadResult), failed(SafeFailure) }
    var readers: Set<UUID> = []
    var completed: Set<UUID> = []
    func setReaders(_ value: Set<UUID>) { readers = value }
    func complete(_ id: UUID) { readers.remove(id); completed.insert(id) }
    func activeTransferIDs() throws -> Set<UUID> { readers }
    func inventories(_ ids: Set<UUID>) throws -> [UUID: Inventory] {
        try Dictionary(uniqueKeysWithValues: ids.map { ($0, try inventory($0)) })
    }
    func inventory(_ id: UUID) throws -> Inventory {
        if completed.contains(id) {
            return .completed(FileUploadResult(data: Data([1]), response: HTTPURLResponse(
                url: URL(string: "https://photos.googleapis.com/")!, statusCode: 200, httpVersion: nil, headerFields: nil)!))
        }
        return readers.contains(id) ? .active : .absent
    }
    func forget(transferID: UUID) { completed.remove(transferID) }

}
private actor SubmittedBoundary: ProviderAdapter {
    nonisolated let provider = Provider.google
    let ledger: Ledger
    let inventory: QueueInventoryBoundary
    var submitted: [(UUID, UUID, UUID)] = []
    init(_ ledger: Ledger, _ inventory: QueueInventoryBoundary) { self.ledger = ledger; self.inventory = inventory }
    var canAcceptWork: Bool { submitted.count < 4 }
    func inspect(destination: Destination, resource: ResourceRequirement) -> RemotePresence { .verifiedAbsent }
    func upload(job: JobRecord, resource: ResourceRequirement, files: [LeasedFile], transferID: UUID,
                progress: @escaping @Sendable (TransferProgress) async -> Void) async -> UploadOutcome {
        do {
            try await ledger.saveProviderCheckpoint(ProviderCheckpoint(destinationID: job.destination.id, tag: resource.tag,
                transferID: transferID, jobID: job.id, phase: .transferring, inputsTerminal: false, payload: Data([1])))
            submitted.append((transferID, job.id, resource.id))
            await inventory.setReaders(Set(submitted.map { $0.0 }))
            return .submitted
        } catch { preconditionFailure("Submission boundary setup failed: \(error)") }
    }
}
private struct QueuePreparer: OriginalPreparer {
    let files: FileLeaseStore
    let ids: [UUID: UUID]
    func prepare(job: JobRecord, resource: ResourceRequirement, receipts: [RemoteReceipt]) async throws -> [LeasedFile] {
        [try await files.acquire(fileID: ids[resource.id]!)]
    }
}
func googleSubmissionChecks(root: URL) async throws {
    var progress = ContinuedWorkProgress()
    check(progress.sample(confirmed: 700, total: 803, fractions: [])?.done == 0, "historical confirmations credited to new grant")
    let next = progress.sample(confirmed: 701, total: 804, fractions: [0.5])!
    check(next.total == 103_000_000 && next.done == 1_500_000, "run denominator moved or real bytes omitted")
    check(progress.sample(confirmed: 701, total: 804, fractions: [.nan, .infinity, -1])?.done == 1_000_000, "invalid progress admitted")
    progress.reset()
    check(progress.sample(confirmed: 803, total: 803, fractions: [])?.done == 1, "empty grant never finishes")
    check(progress.sample(confirmed: 0, total: Int.max, fractions: []) == nil, "progress overflow accepted")

    let ledger = try Ledger(databaseURL: root.appendingPathComponent(UUID().uuidString), version: "offline", revision: "unknown")
    let destination = try await ledger.selectDestination(Destination(provider: .google, verifiedFingerprint: String(repeating: "a", count: 64)))
    try await ledger.completeDestinationRecovery(destination.id)
    let scan = try await ledger.beginScan()
    let assets = try await ledger.registerAssets((0..<6).map {
        AssetIdentity(localIdentifier: "submission-boundary-\($0)", generation: String(repeating: "b", count: 64), kind: .photo)
    }, scanID: scan)
    try await ledger.completeScan(scan)
    let files = try FileLeaseStore(root: root.appendingPathComponent("submitted"), ledger: ledger)
    var ids: [UUID: UUID] = [:]
    for (index, asset) in assets.enumerated() {
        let content = OriginalContent(sha256: String(repeating: String(index), count: 64),
            sha1: String(repeating: String(index), count: 40), byteCount: 3, role: .still)
        let resource = try ContentIdentity.resource(role: .still, originals: [content])
        _ = try await ledger.enqueue(assetID: asset.id, destinationID: destination.id,
            plan: ContentIdentity.plan(policyVersion: "submission-boundary", resources: [resource]))
        let id = UUID(), reservation = try await ledger.reserveStorage(bytes: 3, availableBytes: 2_000_000_000, transportOverhead: 0)
        let writer = try await files.beginExport(fileID: id)
        try Data([1, 2, 3]).write(to: writer.publishedURL)
        let leased = try await files.registerPublished(fileID: id, byteCount: 3, reservationID: reservation.id, reexportable: true)
        try await files.endExport(writer)
        try await files.release(leased)
        ids[resource.id] = id
    }
    let inventory = QueueInventoryBoundary(), boundary = SubmittedBoundary(ledger, inventory)
    let engine = BackupEngine(ledger: ledger, files: files)
    let results = try await engine.runReadyBatch(adapters: [boundary], preparer: QueuePreparer(files: files, ids: ids))
    check(results.count == 1 && results[0].failure == nil && !results[0].requiresRecovery, "OS admission manufactured a failed lane")
    let submitted = await boundary.submitted
    check(submitted.count == 4, "batch did not stop at four owned submissions")
    let counts = try await ledger.snapshot().providers[0]
    check(counts.confirmed == 0 && counts.photos?.failed == 0 && counts.photos?.waiting == 0, "submission shown as saved or failed")
    for (_, jobID, _) in submitted {
        let job = try await ledger.job(jobID)
        check(job.state == .uploading && job.attempts == 1, "submission lost its durable job or spent multiple attempts")
    }
    let retained = try await ledger.retainedTransfers(destinationID: destination.id)
    check(retained.count == 4, "system-owned file protection released after submission")
    await files.completeStartupInventory()
    check(try await files.sweep(limit: 20) == 2, "queued originals were deleted or unrelated originals could not be reclaimed")

    let recovered = GoogleSettlementHarness(ledger, files, inventory)
    let last = retainedForRecovery(try await ledger.retainedTransfers(destinationID: destination.id))
    try await recovered.install(last)
    await inventory.complete(last.id)
    _ = try await recovered.settle(destination, finalize: false)
    check(try await ledger.job(last.job.id).state == .uploading, "startup inventory committed without verified account")
    check(try await ledger.retainedTransfers(destinationID: destination.id).count == 4, "startup inventory released uncommitted receipt")
    _ = try await recovered.settle(destination, finalize: true)
    check(try await ledger.job(last.job.id).state == .confirmed, "terminal OS result was not finalized")
    check(try await ledger.retainedTransfers(destinationID: destination.id).count == 3, "confirmed result still owns staged reader")
    check(await recovered.commits() == 1, "same receipt committed more than once")
    _ = try await recovered.settle(destination, finalize: true)
    check(await recovered.commits() == 1, "recovery replayed an already confirmed submission")

    let admission = GoogleQueueHarness(ledger, inventory)
    check(try await admission.allowsAnother(destination), "settled submission did not free queue slot")
    let first = (try await ledger.retainedTransfers(destinationID: destination.id))[0]
    await inventory.complete(first.id)
    check(try await !admission.allowsAnother(destination), "uncommitted terminal result admitted more work")
    try await ledger.confirm(RemoteReceipt(destinationID: destination.id, tag: first.resource.tag,
        opaqueReference: Data([1]), kind: .uploaded), jobID: first.job.id, resourceID: first.resource.id)
    try await files.transportFinished(first.id)
    check(try await admission.allowsAnother(destination), "confirmed terminal task did not free capacity")
    let heldJob = retained[1].job
    let large = try ContentIdentity.resource(role: .video, originals: [OriginalContent(sha256: String(repeating: "e", count: 64),
        sha1: String(repeating: "e", count: 40), byteCount: 70 * 1024 * 1024, role: .video)])
    let largeJob = JobRecord(id: heldJob.id, destination: destination, asset: heldJob.asset,
        plan: try ContentIdentity.plan(policyVersion: "oversize-boundary", resources: [large]),
        state: .checking, cycleID: heldJob.cycleID, attempts: 0, retryAt: nil)
    check(try await !admission.canAdmit(largeJob), "oversized original overlapped retained small transfers")
    let budget = 64 * 1024 * 1024 - 6
    for (size, accepted) in [(budget, true), (budget + 1, false)] {
        let resource = try ContentIdentity.resource(role: .still, originals: [OriginalContent(
            sha256: String(repeating: "f", count: 64), sha1: String(repeating: "f", count: 40), byteCount: Int64(size), role: .still)])
        let job = JobRecord(id: heldJob.id, destination: destination, asset: heldJob.asset,
            plan: try ContentIdentity.plan(policyVersion: "capacity-boundary", resources: [resource]),
            state: .checking, cycleID: heldJob.cycleID, attempts: 0, retryAt: nil)
        check(try await admission.canAdmit(job) == accepted, "64MiB aggregate capacity boundary is incorrect")
    }
    await inventory.setReaders([UUID()])
    check(try await !admission.allowsAnother(destination), "unknown OS reader bypassed safety fence")
    let claim = try await ledger.claimNext(destinationID: destination.id, runID: UUID())!
    try await ledger.releaseClaim(jobID: claim.id)
    let released = try await ledger.job(claim.id)
    check(released.state == .reconciling && released.attempts == 0, "capacity wait spent an attempt or stranded a claim")
    let remaining = try await ledger.retainedTransfers(destinationID: destination.id)
    await inventory.setReaders(Set(remaining.map(\.id)))
    for transfer in remaining { try await recovered.install(transfer); await inventory.complete(transfer.id) }
    await recovered.failNextCommit()
    _ = try await recovered.settle(destination, finalize: true)
    var unknown = 0, confirmed = 0
    for transfer in remaining {
        let checkpoint = try await ledger.providerCheckpoint(destinationID: destination.id, tag: transfer.resource.tag)!
        if checkpoint.phase == .uncertain { unknown += 1 }
        if try await ledger.job(transfer.job.id).state == .confirmed { confirmed += 1 }
    }
    check(unknown == 1 && confirmed == 1, "ambiguous commit blocked next receipt or was falsely confirmed")
    check(try await ledger.retainedTransfers(destinationID: destination.id).isEmpty, "terminal unknown commit retained an OS reader")
    print("PASS actual Google submission: four bounded durable jobs, no false saved/failure, protected cleanup, terminal/unknown reader gates, oversized exclusion, claim release; finite continued progress")
}

private func retainedForRecovery(_ rows: [RetainedTransfer]) -> RetainedTransfer { rows.last! }

struct SafeProviderFailure: Error, Sendable {
    let failure: SafeFailure
    let retryAfter: Date?
}
actor GoogleCommitBoundary {
    private var count = 0
    private var failNext = false
    func failNextCommit() { failNext = true }
    func recoveredTransfer(_ prepared: PreparedUpload, result: FileUploadResult) throws -> PreparedUpload {
        var value = prepared; value.receipt = result.data; return value
    }
    func commit(prepared: PreparedUpload, useQuota: Bool, saver: Bool, pairedStillHash: Data?,
                phase: @escaping @Sendable (UploadPhase) -> Void) throws -> (mediaKey: String, unused: Bool) {
        check(!useQuota && !saver && prepared.receipt != nil, "quality/storage mode changed during recovered commit")
        count += 1
        if failNext {
            failNext = false
            throw SafeFailure(.timeout, domain: .google, cause: .deadlineExceeded)
        }
        return ("accepted-boundary", false)
    }
    func commits() -> Int { count }
}
