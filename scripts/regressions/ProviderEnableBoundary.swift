import Foundation
import CloudifiedCore

@MainActor final class EnableCancellationBoundary {
    var cancellations = 0
    func cancelOwnedTransfers() async throws { cancellations += 1 }
}
@MainActor final class ProviderEnableHarness {
    struct Settings { var isConnectingGoogle = false, isConnectingTelegram = false }
    var settingsState = Settings()
    var shuttingDown = false, bootstrapComplete = true, controlTransition = false
    var isForeground = true, backgroundExecutionAllowed = false
    var backgroundExpirationTask: Task<Void, Never>?
    var commandProvider: Provider?
    var providerEnableTask: Task<Void, Never>?
    var recoveryTasks: [Provider: Task<Void, Never>] = [:]
    var pendingProviderEnables: [Provider: (value: Bool, revision: UInt64)] = [:]
    var providerMappingRevisions: [Provider: UInt64] = [:]
    let ledger: Ledger?
    let backupEngine: BackupEngine?
    let googleAdapter: EnableCancellationBoundary? = EnableCancellationBoundary()
    var admissions = 0, errors = 0
    init(_ ledger: Ledger, _ engine: BackupEngine) { self.ledger = ledger; backupEngine = engine }
    func beginProviderChange(_ provider: Provider, token: UUID, requiresReleasedInputs: Bool) async throws -> Bool {
        check(commandProvider == nil && recoveryTasks[provider] == nil, "provider commands overlapped recovery or another command")
        commandProvider = provider; admissions += 1
        return true
    }
    func endProviderChange(_ token: UUID) { commandProvider = nil }
    func recoverMapping(_ destination: Destination) async throws {}
    func refreshStoredSettings() async {}
    func report(_ error: any Error, provider: Provider?) async { errors += 1 }
    func scheduleThrottledRefresh() {}
}
@MainActor func providerEnableChecks(root: URL) async throws {
    let fixture = try await fixture(root)
    let files = try FileLeaseStore(root: root.appendingPathComponent("enable-boundary"), ledger: fixture.ledger)
    let owner = ProviderEnableHarness(fixture.ledger, BackupEngine(ledger: fixture.ledger, files: files))
    owner.controlTransition = true
    for value in [false, true, false, true, false] { owner.setEnabled(.google, value) }
    check(owner.providerEnableTask == nil && owner.pendingProviderEnables.count == 1, "pending commands were not bounded/coalesced")
    owner.controlTransition = false; owner.scheduleProviderEnableChanges()
    await owner.providerEnableTask?.value
    check(try await fixture.ledger.snapshot().providers[0].enabled == false && owner.admissions == 1, "latest disabled preference lost")
    check(owner.googleAdapter?.cancellations == 1 && owner.errors == 0, "enable admission manufactured an error")
    owner.recoveryTasks[.google] = Task {}
    owner.setEnabled(.google, true)
    check(owner.providerEnableTask == nil && owner.pendingProviderEnables[.google]?.value == true, "recovery wait discarded preference")
    owner.recoveryTasks.removeAll(); owner.scheduleProviderEnableChanges()
    await owner.providerEnableTask?.value
    check(try await fixture.ledger.snapshot().providers[0].enabled == true && owner.admissions == 2, "recovery completion did not apply pending preference")
    owner.controlTransition = true; owner.setEnabled(.google, false)
    owner.providerMappingRevisions[.google, default: 0] += 1
    owner.controlTransition = false; owner.scheduleProviderEnableChanges()
    await owner.providerEnableTask?.value
    check(owner.admissions == 2 && owner.pendingProviderEnables.isEmpty && owner.errors == 0, "stale preference applied across mapping generation")
    print("PASS actual enable executor: latest intent coalesced, recovery deferral retained, stale mapping intent discarded, no parallel admission or false invariant")
}
