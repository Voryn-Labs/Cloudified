import Foundation
import Combine
@testable import CloudifiedCore

/// Production state store and extracted production resolution method; only the
/// surrounding native boundary is replaced. Nothing is installed into the app.
@MainActor func presentationChecks() {
    let dashboard = ScreenStateStore(0), issues = ScreenStateStore(0)
    var dashboardChanges = 0, issueChanges = 0
    let first = dashboard.objectWillChange.sink { dashboardChanges += 1 }
    let second = issues.objectWillChange.sink { issueChanges += 1 }
    for count in 1...100 { dashboard.value = count; dashboard.value = count }
    check(dashboardChanges == 100 && issueChanges == 0, "progress invalidates unrelated screen or equal state")
    issues.value = 1
    check(dashboardChanges == 100 && issueChanges == 1, "issue update lost")
    withExtendedLifetime((first, second)) {}
    print("PASS actual screen stores: equal snapshots suppressed; 100 progress changes do not publish to Issues")
}

func resolutionChecks() async {
    let failure = SafeFailure(.reconciliation, domain: .tdlib, cause: .outcomeUnknown)
    let receipt = TelegramDocumentReference(version: 1, chatID: -100, messageID: 20, fileID: 4,
        remoteUniqueID: "boundary", byteCount: 3, tag: String(repeating: "b", count: 64), filename: "original.heic")
    let accepted = ResolutionHarness()
    await accepted.set(.confirmed(receipt)); await accepted.set(.uncertain(failure))
    if case .confirmed(let value) = await accepted.result() { check(value == receipt, "receipt changed") }
    else { preconditionFailure("cancellation overwrote native confirmation") }
    let rejected = ResolutionHarness()
    await rejected.set(.rejected(failure, 30)); await rejected.set(.uncertain(failure))
    if case .rejected(_, let retry) = await rejected.result() { check(retry == 30, "retry deadline changed") }
    else { preconditionFailure("timeout overwrote terminal rejection") }
    let uncertain = ResolutionHarness()
    await uncertain.set(.uncertain(failure)); await uncertain.set(.confirmed(receipt))
    if case .confirmed = await uncertain.result() {} else { preconditionFailure("late native success ignored") }
    print("PASS actual Telegram resolution: confirmed/rejected survive cancellation; late success settles uncertainty")
}

func issueMetadataChecks(root: URL) async throws {
    let f = try await fixture(root, provider: .telegram)
    let recipe = Data("{\"hostBoundary\":true}".utf8)
    try await f.ledger.saveSourceRecipe(assetID: f.asset.id, json: recipe)
    let job = try await start(f), transfer = UUID()
    try await f.ledger.holdFiles([], transferID: transfer, job: job, resourceID: f.resource.id)
    try await f.ledger.failAttempt(jobID: job.id,
        failure: UploadFailure(SafeFailure(.reconciliation, domain: .tdlib, cause: .outcomeUnknown), disposition: .waiting, acceptance: .unknown),
        resourceID: f.resource.id, transferID: transfer)
    let page = try await f.ledger.failurePage(provider: .telegram)
    check(page.count == 1 && page[0].recipeData == recipe && page[0].retained, "batched metadata/hold missing")
    let actual = try await f.ledger.job(job.id), batched = page[0].job
    check(batched.id == actual.id && batched.asset == actual.asset && batched.destination == actual.destination
        && batched.plan == actual.plan && batched.cycleID == actual.cycleID && batched.state == actual.state
        && batched.attempts == actual.attempts && batched.retryAt == actual.retryAt, "batched job decoding differs")
    check(try await f.ledger.failurePage(provider: .google).isEmpty, "destination filter ignored")
    check(try await f.ledger.failurePage(beforeCursor: page[0].cursor).isEmpty, "older cursor repeats row")
    try await f.ledger.recordSourceFailure(assetID: f.asset.id, destinationIDs: [f.destination.id],
        error: SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing), permanent: true)
    let source = try await f.ledger.sourceFailurePage()
    check(source.count == 1 && source[0].recipeData == recipe && source[0].occurredAt.timeIntervalSince1970 > 0, "source page metadata missing")
    print("PASS actual issue SQL: batched recipe/job/retained data, source timestamp, provider and keyset filters")
}

func cleanupChecks(root: URL) async throws {
    let f = try await fixture(root)
    let files = try FileLeaseStore(root: root.appendingPathComponent("cleanup-boundary"), ledger: f.ledger)
    var published: [URL] = []
    for _ in 0..<3 {
        let id = UUID(), reservation = try await f.ledger.reserveStorage(bytes: 3, availableBytes: 2_000_000_000, transportOverhead: 0)
        let ownership = try await files.beginExport(fileID: id)
        try Data([1,2,3]).write(to: ownership.publishedURL)
        let lease = try await files.registerPublished(fileID: id, byteCount: 3, reservationID: reservation.id, reexportable: true)
        try await files.endExport(ownership); try await files.release(lease)
        published.append(ownership.publishedURL)
    }
    published.sort { $0.lastPathComponent < $1.lastPathComponent }
    let locked = published[0]
    try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
    defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path) }
    await files.completeStartupInventory()
    check(try await files.sweep(limit: 1) == 0, "immutable file unexpectedly deleted")
    check(try await files.sweep(limit: 1) == 1, "locked first page starved healthy successor")
    check(try await files.sweep(limit: 1) == 1, "cleanup failed to advance to next page")
    check(FileManager.default.fileExists(atPath: locked.path), "failed removal lost protected file")
    try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
    check(try await files.sweep(limit: 1) == 1, "cursor failed to wrap and retry prior file")
    print("PASS actual staging cleanup: immutable first file does not starve later pages; wrap retries it after unlock")
}

func issueIdentificationChecks() {
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let waiting = NotUploadedItem(id: "boundary-wait", destinationID: UUID(), needsRecovery: true,
        filename: "original.heic", captureDate: date, mediaType: "Photo", provider: "Telegram", status: "Waiting",
        technicalCode: "reconciliation/tdlib/pendingSendUnmatched", plainLanguageReason: "Awaiting verified result")
    let failed = NotUploadedItem(id: "boundary-fail", destinationID: UUID(), canRetry: true,
        filename: "original.mov", captureDate: date, mediaType: "Video", provider: "Google Photos", status: "Failed",
        attemptCount: 3, plainLanguageReason: "Provider rejected original")
    var state = NotUploadedViewState(items: [waiting, failed])
    check(state.statusFilter == .all && state.filteredItems.count == 2, "default issue filter hides waiting files")
    check(waiting.statusTitle == "Verify upload" && failed.statusTitle == "Failed", "unknown outcome confused with failed send")
    check(waiting.identificationText.contains("original.heic") && waiting.identificationText.contains("Telegram · Photo")
        && waiting.identificationText.contains("Captured:") && waiting.identificationText.contains("pendingSendUnmatched"), "copied identification lacks file/destination/reason")
    state.statusFilter = .failed
    check(state.filteredItems.map(\.id) == [failed.id], "failed filter includes uncertain item")
    state.statusFilter = .waiting
    check(state.filteredItems.map(\.id) == [waiting.id], "waiting filter hides protected item")
    print("PASS actual issue presentation: All includes waiting/failed; file/date/type/provider identity and technical code copy; filters remain separate")
}
