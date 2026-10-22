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
