import Foundation
@testable import CloudifiedCore

actor MetadataBoundary {
    enum Mode { case valid, malformed, authentication, persistence, optionalDenied }
    let mode: Mode
    var requests = 0
    init(_ mode: Mode) { self.mode = mode }
    func verifiedSubject() throws -> String { "verified-test-subject" }
    func libraryPage(cursor: GoogleLibraryCursor, subject: String) throws -> GoogleLibraryPage {
        requests += 1
        if mode == .optionalDenied { throw SafeFailure(.authentication, domain: .google, code: 403, cause: .loginRequired) }
        if mode == .authentication { throw SafeFailure(.authentication, domain: .google, cause: .loginRequired) }
        if mode == .persistence { throw CoreError.persistence(10) }
        if mode == .malformed { throw SafeFailure(.transfer, domain: .google, cause: .formatRejected) }
        return GoogleLibraryPage(resume: "", sync: "sync-end", items: [], deleted: [])
    }
}
actor GoogleMatchingHarness {
    let session: MetadataBoundary
    let ledger: Ledger
    let catalogURL: URL?
    var catalog: GoogleRemoteIndex?
    var catalogRetry = Date.distantPast
    var catalogScope: String?
    init(_ ledger: Ledger, root: URL, mode: MetadataBoundary.Mode) {
        self.ledger = ledger; session = MetadataBoundary(mode)
        catalogURL = root.appendingPathComponent("google-metadata.sqlite")
    }
    func verify(_ requested: Destination) async throws {
        guard try await ledger.selectedDestination(.google)?.id == requested.id else { throw CoreError.staleMapping }
    }
}
private enum CatalogProbeFailure: Error { case accepted }
private func mustReject(_ operation: () async throws -> Void) async throws {
    do { try await operation(); throw CatalogProbeFailure.accepted }
    catch is CatalogProbeFailure { throw CatalogProbeFailure.accepted }
    catch {}
}
private func mediaRecord(key: String, name: String, quality: UInt64? = 2) -> Data {
    let dimensions = Proto.int(1, 4000) + Proto.int(2, 3000)
    let photo = Proto.bytes(1, Proto.bytes(9, dimensions))
    let info = Proto.string(4, name) + Proto.int(7, 1_700_000_000_000) + Proto.int(10, 4_000_000)
        + (quality.map { Proto.bytes(35, Proto.int(3, $0)) } ?? Data())
    return Proto.string(1, key) + Proto.bytes(2, info) + Proto.bytes(5, Proto.bytes(2, photo))
}
func googleRemoteIndexChecks(root: URL) async throws {
    let folder = root.appendingPathComponent("remote-metadata")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let scope = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
    let index = try GoogleRemoteIndex(url: folder.appendingPathComponent("google-metadata.sqlite"))
    let initial = try await index.bind(scope)
    let item = GoogleRemoteItem(key: "media-1", filename: "IMG_0001.HEIC", bytes: 4_000_000, timestamp: 1_700_000_000, width: 4000, height: 3000, quality: .original)
    let first = try await index.apply(GoogleLibraryPage(resume: "page-two", sync: "end-token", items: [item], deleted: []), expected: initial)
    check(!first.complete && first.rows == 1, "partial page fabricated completed index")
    let reopened = try GoogleRemoteIndex(url: folder.appendingPathComponent("google-metadata.sqlite"))
    check(try await reopened.bind(scope) == first, "restart lost page cursor")
    try await mustReject { _ = try await index.apply(GoogleLibraryPage(resume: "page-two", sync: "", items: [], deleted: []), expected: first) }
    let second = try await index.apply(GoogleLibraryPage(resume: "page-three", sync: "", items: [], deleted: []), expected: first)
    try await mustReject { _ = try await index.apply(GoogleLibraryPage(resume: "page-two", sync: "", items: [], deleted: []), expected: second) }
    let complete = try await index.apply(GoogleLibraryPage(resume: "", sync: "", items: [], deleted: []), expected: second)
    check(complete.complete && complete.sync == "end-token", "terminal page failed to preserve sync epoch")
    check(try await index.candidate(scope: scope, filename: "img_0001.heic", timestamp: item.timestamp, width: 3000, height: 4000, bytes: item.bytes) == .original, "original metadata/rotation candidate lost")
    check(try await index.candidate(scope: scope, filename: item.filename, timestamp: item.timestamp + 100, width: 4000, height: 3000, bytes: item.bytes) == nil, "filename-only collision treated as same photo")
    let tag = String(repeating: "c", count: 64)
    try await index.allowOriginal(scope: scope, tags: [tag])
    check(try await index.isAllowed(scope: scope, tag: tag), "confirmed per-content override lost")
    let switched = try await index.bind(other)
    let leaked = try await index.isAllowed(scope: other, tag: tag)
    check(switched.rows == 0 && !leaked, "account switch leaked catalog/consent")
    try await mustReject { _ = try await index.apply(GoogleLibraryPage(resume: "", sync: "stale", items: [item], deleted: []), expected: first) }
    let saver = GoogleRemoteItem(key: "saver", filename: item.filename, bytes: item.bytes, timestamp: item.timestamp, width: 4000, height: 3000, quality: .storageSaver)
    _ = try await index.apply(GoogleLibraryPage(resume: "", sync: "new-sync", items: [saver], deleted: []), expected: switched)
    check(try await index.candidate(scope: other, filename: item.filename, timestamp: item.timestamp, width: 4000, height: 3000, bytes: item.bytes) == .storageSaver, "Storage Saver was promoted to original")
    let delta = try await index.cursor(scope: other, now: Date().addingTimeInterval(901))
    let deleted = try await index.apply(GoogleLibraryPage(resume: "", sync: "next-sync", items: [], deleted: ["saver"]), expected: delta)
    check(deleted.rows == 0 && deleted.payloadBytes == 0, "deletion failed to release indexed storage budget")
    print("PASS remote index: pagination/restart, repeated cursors, scoped consent, quality, collision and deletion")

    let invalidPages: [(Data, DiagnosticGoogleError)] = [
        (Data(), .libraryEnvelopeInvalid),
        (Data(repeating: 0, count: 4_194_305), .responseLimit),
        (Proto.bytes(1, Proto.bytes(1, Data([255]))), .libraryCursorInvalid),
        (Proto.bytes(1, (0..<5001).reduce(Data()) { data, _ in data + Proto.bytes(2, Data()) }), .libraryPageLimit)
    ]
    for (data, reason) in invalidPages {
        do { _ = try GoogleLibraryWire.page(data); preconditionFailure("invalid metadata accepted") }
        catch let failure as GoogleLibraryWire.Failure { check(failure.reason == reason, "metadata failure lost its precise safe reason") }
    }
    var richBody = Proto.string(6, "rich-sync")
    let padding = Proto.bytes(40, Data(repeating: 1, count: 1800))
    for i in 0..<1000 { richBody += Proto.bytes(2, mediaRecord(key: "rich-\(i)", name: "IMG_\(i).HEIC") + padding) }
    let richData = Proto.bytes(1, richBody)
    check(richData.count > 1_048_576 && richData.count < 4_194_304, "rich metadata did not reproduce the old shared HTTP cap")
    let richPage = try GoogleLibraryWire.page(richData)
    check(richPage.items.count == 1000 && richPage.skipped == 0, "valid rich page was rejected or silently dropped")
    let richFolder = folder.appendingPathComponent("rich")
    try FileManager.default.createDirectory(at: richFolder, withIntermediateDirectories: true)
    let richIndex = try GoogleRemoteIndex(url: richFolder.appendingPathComponent("google-metadata.sqlite"))
    let richCursor = try await richIndex.bind(scope)
    let richComplete = try await richIndex.apply(richPage, expected: richCursor)
    check(richComplete.complete && richComplete.rows == 1000, "rich metadata failed at the cache boundary")
    print("PASS rich metadata: valid page above 1 MiB parses and indexes within the separate 4 MiB budget")
    let encoded = mediaRecord(key: "key", name: "IMG_0001.HEIC")
    let tombstone = Proto.bytes(1, Proto.int(1, 1) + Proto.bytes(2, Proto.string(1, "old-key")))
    let page = try GoogleLibraryWire.page(Proto.bytes(1, Proto.string(6, "sync") + Proto.bytes(2, encoded) + Proto.bytes(2, Data([255])) + Proto.bytes(9, tombstone)))
    check(page.items.count == 1 && page.items[0].quality == .original && page.skipped == 1 && page.deleted == ["old-key"], "one malformed row poisoned page or deletion nesting wrong")
    let unknownRecord = mediaRecord(key: "unknown", name: "IMG_0002.HEIC", quality: 7)
    let unknown = try GoogleLibraryWire.page(Proto.bytes(1, Proto.string(6, "sync") + Proto.bytes(2, unknownRecord)))
    check(unknown.items.first?.quality == .unknown, "unrecognized quality guessed Storage Saver")
    let request = try GoogleLibraryWire.request(initial, subject: "actual-subject")
    check(try Proto.string(at: [1,22,2], in: request) == "actual-subject", "request copied captured account instead of verified subject")
    do {
        _ = try Proto.string(at: [1], in: Proto.bytes(1, Data([255])))
        throw CatalogProbeFailure.accepted
    } catch Proto.Failure.malformed {}
    print("PASS actual library wire: bounded rows, unknown quality, captured identity removal and strict strings")

    let ledger = try Ledger(databaseURL: root.appendingPathComponent(UUID().uuidString), version: "offline", revision: "unknown")
    let destination = try await ledger.selectDestination(Destination(provider: .google, verifiedFingerprint: scope))
    try await ledger.completeDestinationRecovery(destination.id)
    let scan = try await ledger.beginScan()
    let assets = try await ledger.registerAssets((0..<2).map { AssetIdentity(localIdentifier: "metadata-\($0)", generation: scope, kind: .photo) }, scanID: scan)
    try await ledger.completeScan(scan)
    let original = OriginalContent(sha256: scope, sha1: String(repeating: "d", count: 40), byteCount: 4_000_000, role: .still)
    let resource = try ContentIdentity.resource(role: .still, originals: [original])
    let plan = try ContentIdentity.plan(policyVersion: "original-v1", resources: [resource])
    let job = try await ledger.enqueue(assetID: assets[0].id, destinationID: destination.id, plan: plan)
    _ = try await ledger.enqueue(assetID: assets[1].id, destinationID: destination.id,
        plan: ContentIdentity.plan(policyVersion: "other", resources: [try ContentIdentity.resource(role: .still, originals: [OriginalContent(sha256: other, sha1: String(repeating: "e", count: 40), byteCount: 2, role: .still)])]))
    let claimed = try await ledger.claimNext(destinationID: destination.id, runID: UUID())!
    check(claimed.id == job, "unexpected first claim")
    try await ledger.applyPresence(.unknown(SafeFailure(.reconciliation, domain: .google, cause: .possibleOriginalMatch)), jobID: claimed.id, resourceID: resource.id, runID: UUID())
    try await ledger.wakeWaiting(destinationID: destination.id)
    check(try await ledger.job(claimed.id).state == .waiting, "generic recovery wake bypassed candidate decision")
    check(try await ledger.claimNext(destinationID: destination.id, runID: UUID())?.id != claimed.id, "candidate stalled the next file")
    check(try await ledger.googleOverrideTags(jobID: claimed.id, destinationID: destination.id) == [resource.tag], "explicit override not scoped to actual held resource")
    let recipe = try SourceRecipe(assetLocalIdentifier: assets[0].localIdentifier, generation: scope,
        mediaKind: .photo, isLivePhoto: false, resources: [SourceResourceDescriptor(role: .still,
            uti: "public.heic", originalFilename: item.filename, sha256: scope,
            sha1: original.sha1, byteCount: item.bytes)],
        metadata: SourceAssetMetadata(creationDate: Date(timeIntervalSince1970: item.timestamp),
            modificationDate: nil, pixelWidth: 4000, pixelHeight: 3000))
    try await ledger.saveSourceRecipe(assetID: assets[0].id, json: recipe.encode())
    let positiveFolder = root.appendingPathComponent("positive-candidate")
    try FileManager.default.createDirectory(at: positiveFolder, withIntermediateDirectories: true)
    let positiveIndex = try GoogleRemoteIndex(url: positiveFolder.appendingPathComponent("google-metadata.sqlite"))
    let positiveCursor = try await positiveIndex.bind(scope)
    _ = try await positiveIndex.apply(GoogleLibraryPage(resume: "", sync: "ready", items: [item], deleted: []), expected: positiveCursor)
    let positive = GoogleMatchingHarness(ledger, root: positiveFolder, mode: .valid)
    check(try await positive.checkLibraryCandidate(destination, resource: resource)?.cause == .possibleOriginalMatch,
        "actual coordinator ignored a known original candidate")
    check(try await positive.checkLibraryCandidate(destination, resource: resource, acceptedOriginals: [scope]) == nil,
        "already accepted Live Photo component was held as a new candidate")
    try await positive.allowOriginal(jobID: claimed.id, destination: destination)
    check(try await positive.checkLibraryCandidate(destination, resource: resource) == nil,
        "explicit consent failed to release only the candidate guard")
    let harness = GoogleMatchingHarness(ledger, root: folder, mode: .malformed)
    let failure = try await harness.checkLibraryCandidate(destination, resource: resource)
    check(failure == nil, "optional metadata endpoint failure blocked exact-hash fallback")
    _ = try await harness.checkLibraryCandidate(destination, resource: resource)
    check(await harness.session.requests == 1, "metadata endpoint failure retried for every file")
    for mode in [MetadataBoundary.Mode.authentication, .persistence] {
        let gated = GoogleMatchingHarness(ledger, root: positiveFolder, mode: mode)
        // Expire the completed cache so the real coordinator performs a request.
        _ = try await positiveIndex.cursor(scope: scope, now: Date().addingTimeInterval(901))
        try await mustReject { _ = try await gated.checkLibraryCandidate(destination, resource: resource) }
    }
    let denied = GoogleMatchingHarness(ledger, root: positiveFolder, mode: .optionalDenied)
    check(try await denied.checkLibraryCandidate(destination, resource: resource) == nil,
        "metadata-only denial blocked the already verified original upload path")
    let damagedFolder = root.appendingPathComponent("damaged-optional-cache")
    try FileManager.default.createDirectory(at: damagedFolder, withIntermediateDirectories: true)
    let damagedURL = damagedFolder.appendingPathComponent("google-metadata.sqlite")
    let damagedIndex = try GoogleRemoteIndex(url: damagedURL)
    _ = try await damagedIndex.bind(scope)
    let damagedDB = try SQLite(url: damagedURL)
    try damagedDB.execute("UPDATE catalog_state SET body=? WHERE id=1", [.blob(Data([255]))])
    let damaged = GoogleMatchingHarness(ledger, root: damagedFolder, mode: .valid)
    check(try await damaged.checkLibraryCandidate(destination, resource: resource) == nil,
        "disposable cache corruption became a destination gate")
    check(await damaged.catalog == nil, "failed optional cache retained a per-file error loop")
    print("PASS matching isolation: candidate leaves queue moving, manual consent, endpoint cooldown and legacy fallback")
}

func googleReconciliationLimitChecks(root: URL) async throws {
    let f = try await fixture(root)
    let checkpoint = ProviderCheckpoint(destinationID: f.destination.id, tag: f.resource.tag,
        transferID: UUID(), jobID: f.jobID, phase: .uncertain, inputsTerminal: true, payload: Data("protected-legacy".utf8))
    try await f.ledger.saveProviderCheckpoint(checkpoint)
    var now = Date()
    for index in 0..<3 {
        let job = try await f.ledger.claimNext(destinationID: f.destination.id, runID: UUID(), now: now)!
        try await f.ledger.applyPresence(.unknown(SafeFailure(.reconciliation, domain: .google, cause: .outcomeUnknown)),
            jobID: job.id, resourceID: f.resource.id, runID: UUID())
        let waiting = try await f.ledger.job(job.id)
        try await f.ledger.wakeWaiting(destinationID: f.destination.id)
        try await f.ledger.unblockDestination(f.destination.id)
        let afterWake = try await f.ledger.job(job.id)
        check(afterWake.state == .waiting && afterWake.retryAt == waiting.retryAt, "generic wake bypassed Google verification delay/cap")
        if index < 2 {
            check(waiting.retryAt != nil, "verification lost bounded retry timer")
            check(try await f.ledger.claimNext(destinationID: f.destination.id, runID: UUID(), now: Date()) == nil,
                "verification ran before its persisted deadline")
            now = waiting.retryAt!.addingTimeInterval(1)
        } else {
            check(waiting.retryAt == nil, "three failed verifications still schedule endless polling")
            check(try await f.ledger.claimNext(destinationID: f.destination.id, runID: UUID(), now: now.addingTimeInterval(86400)) == nil,
                "time bypassed the explicit-review quarantine")
        }
    }
    let databaseURL = try await f.ledger.reconciliationProbeURL()
    let reopened = try Ledger(databaseURL: databaseURL, version: "offline", revision: "unknown")
    try await reopened.completeDestinationRecovery(f.destination.id)
    try await reopened.unblockDestination(f.destination.id)
    check(try await reopened.claimNext(destinationID: f.destination.id, runID: UUID(), now: Date().addingTimeInterval(86400)) == nil,
        "process restart bypassed verification quarantine")
    let scan = try await f.ledger.beginScan()
    let assets = try await f.ledger.registerAssets([f.asset, AssetIdentity(localIdentifier: "unrelated-ready-file",
        generation: String(repeating: "e", count: 64), kind: .photo)], scanID: scan)
    try await f.ledger.completeScan(scan)
    let content = OriginalContent(sha256: String(repeating: "e", count: 64), sha1: String(repeating: "d", count: 40), byteCount: 9, role: .still)
    let resource = try ContentIdentity.resource(role: .still, originals: [content])
    let other = try await f.ledger.enqueue(assetID: assets[1].id, destinationID: f.destination.id,
        plan: ContentIdentity.plan(policyVersion: "independent", resources: [resource]))
    let ready = try await f.ledger.claimNext(destinationID: f.destination.id, runID: UUID())!
    check(ready.id == other, "quarantined Google file blocked unrelated ready work")
    try await f.ledger.applyPresence(.unknown(SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)),
        jobID: ready.id, resourceID: resource.id, runID: UUID())
    try await f.ledger.explicitRetry(jobID: f.jobID)
    let retry = try await f.ledger.claimNext(destinationID: f.destination.id, runID: UUID())
    check(retry?.id == f.jobID, "explicit user review could not recheck the held item")
    let preserved = try await f.ledger.providerCheckpoint(destinationID: f.destination.id, tag: f.resource.tag)
    check(preserved?.transferID == checkpoint.transferID && preserved?.phase == .uncertain && preserved?.payload == checkpoint.payload,
        "manual verification erased legacy uncertain acceptance evidence")
    print("PASS Google reconciliation cap: persisted deadlines, three checks, generic wake immunity and explicit verification without resend proof loss")
}

private extension Ledger {
    func reconciliationProbeURL() throws -> URL {
        guard let row = try db.rows("PRAGMA database_list").first else { throw ProbeError.rollback }
        return URL(fileURLWithPath: try row.string("file"))
    }
}

actor ReceiptRecoveryBoundary {
    enum Result { case accepted, timeout, empty, authentication }
    var result: Result
    let ledger: Ledger
    let destination: Destination
    let resource: ResourceRequirement
    var hashKey: String?
    var requests = 0
    init(_ f: Fixture, result: Result) { ledger=f.ledger; destination=f.destination; resource=f.resource; self.result=result }
    func use(_ result: Result) { self.result=result }
    func find(_ key: String) { hashKey=key }
    func calls() -> Int { requests }
    func checkPresence(sha1: Data, asLivePhotoMotion: Bool) -> String? { hashKey }
    func commit(prepared: PreparedUpload, useQuota: Bool, saver: Bool, pairedStillHash: Data?,
                phase: @escaping @Sendable (UploadPhase) -> Void, context: EventContext? = nil) async throws -> (mediaKey: String, unused: Bool) {
        check(!useQuota && !saver && prepared.receipt != nil, "receipt recovery changed original/nonquota mode")
        let checkpoint = try await ledger.providerCheckpoint(destinationID: destination.id, tag: resource.tag)
        check(checkpoint?.phase == .committing, "receipt replay started without durable acceptance fence")
        requests += 1
        switch result {
        case .accepted: return ("verified-google-key", false)
        case .empty: return ("", false)
        case .timeout: throw SafeFailure(.timeout, domain: .google, cause: .deadlineExceeded)
        case .authentication: throw SafeProviderFailure(failure: SafeFailure(.authentication, domain: .google, cause: .loginRequired), retryAfter: nil)
        }
    }
}
func receiptRecoveryChecks(root: URL) async throws {
    func install(_ f: Fixture, phase: ProviderCheckpointPhase = .uncertain, commitIndex: Int? = 0) async throws -> ProviderCheckpoint {
        let prepared = PreparedUpload(uploadURL: URL(string: "https://photos.googleapis.com/data/upload/uploadmedia/interactive?upload_id=fixture")!,
            hash: try ProviderSupport.hex(f.resource.originals[0].sha1, count: 20), filename: "fixture.heic", modified: Date(), byteCount: 3,
            receipt: Proto.string(2, "existing-upload-token"))
        struct LegacyState: Codable { let prepared: [PreparedUpload?]; let mediaKeys: [String?]; let commitIndex: Int?; let didUpload: Bool }
        let state = LegacyState(prepared: [prepared], mediaKeys: [nil], commitIndex: commitIndex, didUpload: true)
        let checkpoint = ProviderCheckpoint(destinationID: f.destination.id, tag: f.resource.tag, transferID: UUID(), jobID: f.jobID,
            phase: phase, inputsTerminal: true, payload: try JSONEncoder().encode(state))
        try await f.ledger.saveProviderCheckpoint(checkpoint)
        return checkpoint
    }
    let accepted = try await fixture(root)
    _ = try await install(accepted)
    let server = ReceiptRecoveryBoundary(accepted, result: .accepted)
    let adapter = ReceiptRecoveryHarness(accepted.ledger, server)
    let result = await adapter.inspect(destination: accepted.destination, resource: accepted.resource)
    guard case .present = result else { preconditionFailure("saved receipt could not finish the stuck legacy upload") }
    check(try await accepted.ledger.snapshot().providers[0].confirmed == 0, "request alone fabricated Saved before Core confirmation")
    _ = try await accepted.ledger.claimNext(destinationID: accepted.destination.id, runID: UUID())
    try await accepted.ledger.applyPresence(result, jobID: accepted.jobID, resourceID: accepted.resource.id, runID: UUID())
    check(try await accepted.ledger.snapshot().providers[0].confirmed == 1, "real commit key did not confirm the original")
    check(await server.calls() == 1, "receipt recovery repeated successful finalization")

    let failed = try await fixture(root)
    let old = try await install(failed)
    let rejectedServer = ReceiptRecoveryBoundary(failed, result: .empty)
    let rejectedAdapter = ReceiptRecoveryHarness(failed.ledger, rejectedServer)
    for _ in 0..<2 {
        let value = await rejectedAdapter.inspect(destination: failed.destination, resource: failed.resource)
        guard case .unknown = value else { preconditionFailure("empty Google key fabricated Saved") }
    }
    let exhausted = await rejectedAdapter.inspect(destination: failed.destination, resource: failed.resource)
    guard case .unknown(let error) = exhausted else { preconditionFailure("failed commit counted as saved") }
    let failedCalls = await rejectedServer.calls()
    check(error.cause == .commitRecoveryExhausted && failedCalls == 2, "legacy original plus recovery exceeded three submissions")
    _ = try await failed.ledger.claimNext(destinationID: failed.destination.id, runID: UUID())
    try await failed.ledger.applyPresence(exhausted, jobID: failed.jobID, resourceID: failed.resource.id, runID: UUID())
    let counts = try await failed.ledger.snapshot().providers[0]
    check(counts.confirmed == 0 && counts.photos?.failed == 1, "exhausted commit did not remain visibly failed/unconfirmed")
    let restarted = ReceiptRecoveryHarness(failed.ledger, rejectedServer)
    _ = await restarted.inspect(destination: failed.destination, resource: failed.resource)
    check(await rejectedServer.calls() == 2, "restart reset the persistent finalization budget")
    let checkpoint = try await failed.ledger.providerCheckpoint(destinationID: failed.destination.id, tag: failed.resource.tag)
    check(checkpoint?.phase == .uncertain && checkpoint?.transferID == old.transferID, "failed recovery erased uncertain evidence")
    try await restarted.resetFinalizationBudget(jobID: failed.jobID, destination: failed.destination)
    await rejectedServer.use(.accepted)
    let retried = await restarted.inspect(destination: failed.destination, resource: failed.resource)
    guard case .present = retried else { preconditionFailure("explicit receipt retry could not recover") }
    let ready = try await fixture(root)
    _ = try await install(ready, phase: .rejected, commitIndex: nil)
    let readyServer = ReceiptRecoveryBoundary(ready, result: .accepted)
    let readyAdapter = ReceiptRecoveryHarness(ready.ledger, readyServer)
    let readyResult = await readyAdapter.inspect(destination: ready.destination, resource: ready.resource)
    guard case .present = readyResult else { preconditionFailure("never-submitted receipt was replaced by another media upload") }
    check(await readyServer.calls() == 1, "receipt-ready checkpoint was not finalized directly")

    let scan = try await failed.ledger.beginScan()
    let assets = try await failed.ledger.registerAssets([failed.asset, AssetIdentity(localIdentifier: "healthy-after-finalization-error",
        generation: String(repeating: "e", count: 64), kind: .photo)], scanID: scan)
    try await failed.ledger.completeScan(scan)
    let healthyOriginal = OriginalContent(sha256: String(repeating: "e", count: 64), sha1: String(repeating: "e", count: 40), byteCount: 9, role: .still)
    let healthyResource = try ContentIdentity.resource(role: .still, originals: [healthyOriginal])
    let healthy = try await failed.ledger.enqueue(assetID: assets[1].id, destinationID: failed.destination.id,
        plan: ContentIdentity.plan(policyVersion: "independent", resources: [healthyResource]))
    check(try await failed.ledger.claimNext(destinationID: failed.destination.id, runID: UUID())?.id == healthy,
        "failed finalization stopped the next Google item")

    let preflight = try await fixture(root)
    let beforeLookup = try await install(preflight)
    let preflightServer = ReceiptRecoveryBoundary(preflight, result: .accepted)
    let preflightAdapter = ReceiptRecoveryHarness(preflight.ledger, preflightServer)
    await preflightAdapter.failContextLookup()
    _ = await preflightAdapter.inspect(destination: preflight.destination, resource: preflight.resource)
    let afterLookup = try await preflight.ledger.providerCheckpoint(destinationID: preflight.destination.id, tag: preflight.resource.tag)
    check(afterLookup?.payload == beforeLookup.payload && afterLookup?.phase == beforeLookup.phase,
        "context lookup failure consumed finalization attempt or changed acceptance fence")
    check(await preflightServer.calls() == 0, "failed context lookup sent finalization")

    let timeout = try await fixture(root)
    _ = try await install(timeout)
    let timeoutServer = ReceiptRecoveryBoundary(timeout, result: .timeout)
    let timeoutAdapter = ReceiptRecoveryHarness(timeout.ledger, timeoutServer)
    let pending = await timeoutAdapter.inspect(destination: timeout.destination, resource: timeout.resource)
    guard case .unknown(let pendingError) = pending else { preconditionFailure("timeout fabricated acceptance") }
    check(pendingError.cause == .commitRecoveryPending, "retryable finalization did not schedule receipt-only recovery")
    _ = try await timeout.ledger.claimNext(destinationID: timeout.destination.id, runID: UUID())
    try await timeout.ledger.applyPresence(pending, jobID: timeout.jobID, resourceID: timeout.resource.id, runID: UUID())
    let deadline = try await timeout.ledger.job(timeout.jobID).retryAt
    try await timeout.ledger.wakeWaiting(destinationID: timeout.destination.id)
    try await timeout.ledger.unblockDestination(timeout.destination.id)
    let afterWake = try await timeout.ledger.job(timeout.jobID).retryAt
    check(deadline != nil && afterWake == deadline,
        "generic wake bypassed receipt recovery backoff")
    await timeoutServer.use(.accepted)
    let recovered = await timeoutAdapter.inspect(destination: timeout.destination, resource: timeout.resource)
    guard case .present = recovered else { preconditionFailure("server recovery did not finalize the existing receipt") }

    let protected = try await fixture(root)
    let protectedCheckpoint = try await install(protected)
    let protectedServer = ReceiptRecoveryBoundary(protected, result: .accepted)
    let inventory = QueueInventoryBoundary()
    await inventory.setReaders([protectedCheckpoint.transferID])
    let protectedAdapter = ReceiptRecoveryHarness(protected.ledger, protectedServer, background: inventory)
    _ = await protectedAdapter.inspect(destination: protected.destination, resource: protected.resource)
    check(await protectedServer.calls() == 0, "active OS reader permitted finalization replay")
    await inventory.setReaders([])
    await inventory.loseJournal(protectedCheckpoint.transferID, readerActive: false)
    _ = await protectedAdapter.inspect(destination: protected.destination, resource: protected.resource)
    check(await protectedServer.calls() == 0, "unavailable OS inventory permitted finalization replay")
    await inventory.repairJournal(protectedCheckpoint.transferID)
    await protectedServer.find("existing-original-key")
    let found = await protectedAdapter.inspect(destination: protected.destination, resource: protected.resource)
    guard case .present = found else { preconditionFailure("exact existing original was not recognized before receipt recovery") }
    check(await protectedServer.calls() == 0, "exact existing original triggered receipt replay")

    let auth = try await fixture(root)
    _ = try await install(auth)
    let authServer = ReceiptRecoveryBoundary(auth, result: .authentication)
    let authAdapter = ReceiptRecoveryHarness(auth.ledger, authServer)
    let blocked = await authAdapter.inspect(destination: auth.destination, resource: auth.resource)
    guard case .destinationBlocked(let authError, _) = blocked else { preconditionFailure("real account fault became an isolated file failure") }
    check(authError.category == .authentication, "receipt recovery obscured sign-in guidance")
    print("PASS actual receipt recovery: legacy stuck upload finalizes without a PUT; empty keys never Saved, three-call persisted cap and explicit recovery")
}

func diagnosticRootChecks(root: URL) async throws {
    let f = try await fixture(root)
    let failure = SafeFailure(.transfer, domain: .google, code: 500, cause: .providerRejected)
    let owner = EventContext(origin: .google, destinationID: f.destination.id, jobID: f.jobID,
        resourceID: f.resource.id, diagnostic: DiagnosticDetail(stage: .googleCommit, status: .failed,
            correlationID: UUID(), httpStatus: 500, responseBytes: 7, googleStatus: 13, responseKind: .protobuf, requestSubmitted: true))
    let serverError = GPMCError(kind: .server(500), message: "PRIVATE SERVER MESSAGE", status: GoogleStatus(Proto.int(1, 13)),
        httpStatus: 500, responseBytes: 7, responseKind: .protobuf)
    await GoogleTraceHarness(f.ledger).probe(owner, error: serverError)
    _ = try await f.ledger.claimNext(destinationID: f.destination.id, runID: UUID())
    try await f.ledger.applyPresence(.unknown(failure), jobID: f.jobID, resourceID: f.resource.id, runID: UUID())
    try await f.ledger.saveProviderCheckpoint(ProviderCheckpoint(destinationID: f.destination.id, tag: f.resource.tag,
        transferID: UUID(), jobID: f.jobID, phase: .uncertain, inputsTerminal: true, payload: Data("NEVER-EXPORT-PRIVATE-RECEIPT".utf8)))
    for _ in 0..<200 {
        try await f.ledger.appendEvent(.remoteCheck, context: EventContext(origin: .google, jobID: f.jobID),
            decision: .reconcile, severity: .warning, failure: SafeFailure(.reconciliation, domain: .google, cause: .outcomeUnknown))
    }
    _ = try await f.ledger.pruneDiagnostics(byteBudget: 8000)
    let roots = try await f.ledger.logPage(limit: 100, reportFocus: .rootCauses)
    check(roots.events.contains { $0.failure?.code == 500 && $0.context.jobID == f.jobID }, "repeat warnings displaced the original structured Google failure")
    let actualTrace = roots.events.first { $0.context.diagnostic?.stage == .googleCommit }?.context.diagnostic
    check(actualTrace?.googleStatus == 13 && actualTrace?.httpStatus == 500 && actualTrace?.requestSubmitted == true,
        "actual session trace lost Google protocol/submission evidence")
    try await GoogleTraceHarness(f.ledger).success(owner)
    let traceEvents = try await f.ledger.logPage(origin: .google, limit: 100)
    check(traceEvents.events.contains { $0.context.diagnostic?.stage == .googleCommit && $0.context.diagnostic?.status == .succeeded && $0.context.diagnostic?.requestSubmitted == true }, "successful commit omitted submission proof")
    check(traceEvents.events.filter { $0.context.diagnostic?.stage == .googleCommit && $0.context.diagnostic?.status == .failed }.count == 1, "traced duplicated or lost the original failure")
    check(!traceEvents.events.contains { $0.context.diagnostic?.status == .started && $0.context.diagnostic?.requestSubmitted == true }, "unstarted trace claimed dispatch")
    let evidence = try await f.ledger.diagnosticStateJSONL(limit: 12)
    let text = String(decoding: evidence, as: UTF8.self)
    check(text.contains("queueSnapshot") && text.contains("jobEvidence") && text.contains("firstFailure") && text.contains("500"), "report omitted current queue and original failure")
    check(text.contains("uncertain") && text.contains("inputsTerminal"), "report omitted sanitized checkpoint phase")
    check(!text.contains("NEVER-EXPORT") && !text.contains(Data("NEVER-EXPORT-PRIVATE-RECEIPT".utf8).base64EncodedString())
        && !text.contains(f.asset.localIdentifier) && !text.contains(f.resource.originals[0].sha1), "state export leaked private content")
    let output = root.appendingPathComponent(UUID().uuidString + ".jsonl")
    try await f.ledger.exportDiagnostics(to: output)
    check(try String(contentsOf: output, encoding: .utf8).contains("queueSnapshot"), "full diagnostic export lost queue evidence")
    try await f.ledger.auditMalformedCheckpoint()
    let degraded = String(decoding: try await f.ledger.diagnosticStateJSONL(limit: 12), as: UTF8.self)
    check(degraded.contains("stateCoverage") && degraded.contains("unreadableCheckpointGroups") && !degraded.contains("PRIVATE_BAD_PHASE"), "invalid checkpoint aborted export or leaked unknown value")
    let scan = try await f.ledger.beginScan()
    let assets = try await f.ledger.registerAssets([f.asset] + (0..<12).map { AssetIdentity(localIdentifier: "audit-budget-\($0)", generation: String(repeating: "c", count: 64), kind: .photo) }, scanID: scan)
    try await f.ledger.completeScan(scan)
    for (index, asset) in assets.dropFirst().enumerated() {
        let original = OriginalContent(sha256: String(format: "%064x", index + 1), sha1: String(format: "%040x", index + 1), byteCount: 10, role: .still)
        let resource = try ContentIdentity.resource(role: .still, originals: [original])
        _ = try await f.ledger.enqueue(assetID: asset.id, destinationID: f.destination.id, plan: ContentIdentity.plan(policyVersion: "audit", resources: [resource]))
    }
    let bounded = try await f.ledger.diagnosticStateJSONL(limit: 100, byteBudget: 4096)
    check(bounded.count <= 4096 && String(decoding: bounded, as: UTF8.self).contains("\"byteLimited\":true"), "oversized state failed instead of truncating with coverage")
    try await f.ledger.auditMalformedCheckpoint(raw: true)
    check(try await f.ledger.auditTransferIndex(), "transfer lookup still uses an unindexed scan")
    let degradedExport = root.appendingPathComponent(UUID().uuidString + ".jsonl")
    try await f.ledger.exportDiagnostics(to: degradedExport)
    try await f.ledger.auditInvalidState()
    let fallbackExport = root.appendingPathComponent(UUID().uuidString + ".jsonl")
    try await f.ledger.exportDiagnostics(to: fallbackExport)
    let fallbackText = try String(contentsOf: fallbackExport, encoding: .utf8)
    check(fallbackText.contains("stateUnavailable") && fallbackText.contains("googleCommit") && !fallbackText.contains("PRIVATE_BAD_STATE"),
        "unreadable state aborted event export or leaked corrupted text")
    print("PASS audit export: malformed checkpoint skipped explicitly; tight byte budget truncates and full export remains usable")
    print("PASS diagnostic roots: first HTTP failure survives repeat storm; bounded queue/checkpoint evidence excludes private receipts, names and hashes")
}

extension Ledger {
    func auditMalformedCheckpoint(raw: Bool = false) throws {
        if raw { try db.execute("UPDATE provider_checkpoints SET body=X'ff'") }
        else { try db.execute("UPDATE provider_checkpoints SET body=json_set(CAST(body AS TEXT),'$.phase','PRIVATE_BAD_PHASE')") }
    }
    func auditInvalidState() throws { try db.execute("UPDATE jobs SET state='PRIVATE_BAD_STATE'") }
    func auditTransferIndex() throws -> Bool {
        try db.rows("EXPLAIN QUERY PLAN SELECT COUNT(*) FROM transfers WHERE job_id=?", [.text(UUID().uuidString)])
            .contains { ((try? $0.string("detail")) ?? "").contains("transfers_job") }
    }
}
