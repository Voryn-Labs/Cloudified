import Foundation
@testable import CloudifiedCore

actor BackupRequestEngineBoundary {
    func resume() async throws {}
}

@MainActor final class BackupRequestHarness {
    var shuttingDown = false
    var backgroundExpirationTask: Task<Void, Never>?
    var commandProvider: Provider?
    var controlTransition = false
    var backupExecutionTask: Task<Void, Never>?
    var backupRequested = true
    var needsFreshScan = false
    var pausedByUser = false
    var resumeAfterExpiration = false
    var backupIntent: DiagnosticBackupIntent = .automatic
    var systemError: SafeFailure?
    var backupEngine: BackupRequestEngineBoundary?
    var ledger: Ledger?
    var continuationIntent: DiagnosticBackupIntent?
    var policyUpdates = 0, refreshes = 0, drainRequests = 0
    func requestContinuation() { continuationIntent = backupIntent }
    func schedulePolicyUpdate() { policyUpdates += 1 }
    func scheduleThrottledRefresh() { refreshes += 1 }
    func requestDrain() { drainRequests += 1 }
    func report(_ error: any Error, provider: Provider?) async {}
}

@MainActor func activeBackupRequestChecks() {
    let active = BackupRequestHarness()
    active.backupExecutionTask = Task {}
    active.requestBackup()
    check(active.backupIntent == .explicit && active.continuationIntent == .explicit,
          "active Start lost explicit continuation intent")
    check(!active.needsFreshScan && !active.controlTransition && active.drainRequests == 1,
          "active Start restarted planning or entered a second control transition")
    check(active.policyUpdates == 1 && active.refreshes == 1, "active request not published")
    for blocked in 0..<4 {
        let request = BackupRequestHarness()
        request.backupExecutionTask = Task {}
        switch blocked {
        case 0: request.shuttingDown = true
        case 1: request.backgroundExpirationTask = Task {}
        case 2: request.commandProvider = .telegram
        default: request.controlTransition = true
        }
        request.requestBackup()
        check(request.backupIntent == .automatic && request.continuationIntent == nil
              && request.drainRequests == 0, "Start bypassed settlement/control guard")
    }
    print("PASS actual active Start: explicit continuation, no fresh scan, settlement guards preserved")
}

func diagnosticPrivacyChecks(root: URL) async throws {
    let ledger = try Ledger(databaseURL: root.appendingPathComponent(UUID().uuidString),
                            version: "offline", revision: "unknown")
    let destination = try await ledger.selectDestination(Destination(provider: .telegram,
        verifiedFingerprint: String(repeating: "e", count: 64)))
    let scan = try await ledger.beginScan()
    let marker = "PRIVATE-CONTENT-MUST-NOT-BE-EXPORTED"
    let asset = try await ledger.registerAssets([AssetIdentity(localIdentifier: marker,
        generation: String(repeating: "a", count: 64), kind: .photo)], scanID: scan)[0]
    try await ledger.completeScan(scan)
    try await ledger.bindProviderProfile(destination: destination, profileID: "primary", scope: Data(marker.utf8))
    try await ledger.saveSourceRecipe(assetID: asset.id,
        json: JSONSerialization.data(withJSONObject: ["originalFilename": marker, "privatePath": marker]))
    let failure = SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)
    try await ledger.recordSourceFailure(assetID: asset.id, destinationIDs: [destination.id],
        error: failure, permanent: true)
    let metadata = DiagnosticReportMetadata(version: "offline", build: "0", revision: "boundary",
        osMajor: 26, osMinor: 0, osPatch: 0, providerClientsAvailable: false,
        googleCredentialAvailable: false,
        network: DiagnosticDetail(stage: .networkPolicy, status: .changed, correlationID: UUID()))
    let report = try await DiagnosticReportUploader().buildReport(ledger: ledger, metadata: metadata,
        fallback: [DiagnosticReportFallback(timestamp: Date(), failure: failure)])
    let text = String(decoding: report, as: UTF8.self)
    check(!text.contains(marker) && !text.contains(destination.verifiedFingerprint),
          "public report leaked source identifiers, recipe, account scope or fingerprint")
    check(text.contains("sourceMissing") && text.contains("selectedEvents") && text.contains("queueSnapshot") && text.contains("rootCauses"),
          "privacy check removed useful failure evidence")
    check(report.count <= 256 * 1024, "public report exceeded its bounded budget")
    for line in text.split(separator: "\n") {
        _ = try JSONSerialization.jsonObject(with: Data(line.utf8))
    }
    print("PASS actual public report: private ledger metadata excluded; typed failures retained; bounded JSONL, no network")
}

actor LocalResetSessionBoundary {
    var hasNativeClient: Bool
    init(active: Bool) { hasNativeClient = active }
}

actor LocalResetHarness {
    let profileID = "primary"
    let credentialStore: KeychainCredentialStore
    let session: LocalResetSessionBoundary
    let root: URL
    var isStarting = false
    // This filesystem boundary supplies temporary directories, never app data.
    func storageURLsForBoundary(forProfile profileID: String) throws -> (databaseURL: URL, filesURL: URL) {
        return (root.appendingPathComponent("database"), root.appendingPathComponent("files"))
    }
    static func storageFailure(_ error: any Error) -> SafeFailure {
        SafeFailure(.sourceUnavailable, domain: .fileSystem, cause: .storageUnavailable)
    }
    init(root: URL, store: KeychainCredentialStore, active: Bool) {
        self.root = root; credentialStore = store; session = LocalResetSessionBoundary(active: active)
    }
}

@MainActor func localResetChecks(root: URL) async throws {
    let local = root.appendingPathComponent(UUID().uuidString)
    let db = local.appendingPathComponent("database"), files = local.appendingPathComponent("files")
    try FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    let marker = db.appendingPathComponent("database-boundary")
    try Data([1]).write(to: marker)
    let present = boundaryCredentialStore()
    _ = try present.getOrCreateTDLibDatabaseKey(forProfile: "primary")
    do {
        try await LocalResetHarness(root: local, store: present, active: false).resetLocalDatabaseAfterKeyLoss()
        preconditionFailure("reset discarded a configured database key")
    } catch CoreError.invalidTransition { }
    let missing = boundaryCredentialStore()
    do {
        try await LocalResetHarness(root: local, store: missing, active: true).resetLocalDatabaseAfterKeyLoss()
        preconditionFailure("reset removed native-owned database")
    } catch CoreError.recoveryRequired { }
    check(FileManager.default.fileExists(atPath: marker.path), "blocked reset changed database bytes")
    try await LocalResetHarness(root: local, store: missing, active: false).resetLocalDatabaseAfterKeyLoss()
    check(!FileManager.default.fileExists(atPath: db.path) && !FileManager.default.fileExists(atPath: files.path),
          "missing-key reset left unreadable database/cache")

    let retained = try await fixture(root, provider: .telegram)
    let job = try await start(retained)
    try await retained.ledger.holdFiles([], transferID: UUID(), job: job, resourceID: retained.resource.id)
    try await retained.ledger.deselectDestination(retained.destination.id)
    let harness = BackupRequestHarness(); harness.ledger = retained.ledger
    do {
        try await harness.requireNoRetainedInputs(.telegram)
        preconditionFailure("deselected mapping's unresolved send did not block reset")
    } catch { check((error as? SafeFailure)?.cause == .outcomeUnknown, "retained reset gate misclassified") }
    try await harness.requireNoRetainedInputs(.google)
    print("PASS actual local reset: existing key/native owner blocks deletion; missing key permits local reset; deselected retained Telegram mapping blocks; Google stays independent")
}
