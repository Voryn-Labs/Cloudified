import Foundation
import CloudifiedCore

extension AppEnvironment {
    func requestRecovery(_ provider: Provider, force: Bool = false) {
        if force { forceRecovery.insert(provider) }
        guard bootstrapComplete, allowedNetwork, policyGate == nil, !shuttingDown else { return }
        if commandProvider != nil || recoveryTasks[provider] != nil { recoveryWake.insert(provider); return }
        recoveryWake.remove(provider)
        recoveryTasks[provider] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.recoveryTasks[provider] = nil; self.scheduleThrottledRefresh()
                if self.recoveryWake.remove(provider) != nil { self.requestRecovery(provider) }
            }
            do {
                guard let ledger = self.ledger else { return }
                let snapshot = try await ledger.snapshot()
                // Foreground/resume and connection events must not bypass a
                // persisted provider flood wait by unblocking it in recovery.
                if let blocked = snapshot.providers.first(where: { $0.provider == provider }),
                   blocked.blockedReason?.category == .rateLimit, let deadline = blocked.resumeAt, deadline > Date() {
                    self.retryDeadlines[provider] = deadline
                    self.scheduleRetryDeadline(self.retryDeadlines.values.min())
                    return
                }
                var recoveredNow = false
                let selected = try await ledger.selectedDestination(provider)
                var hasRetained = false
                if let selected { hasRetained = try await !ledger.retainedTransfers(destinationID: selected.id, limit: 1).isEmpty }
                let forced = self.forceRecovery.remove(provider) != nil
                if !hasRetained && !forced && snapshot.providers.first(where: { $0.provider == provider })?.recoveryComplete == true && snapshot.providers.first(where: { $0.provider == provider })?.blockedReason == nil {
                    if let destination = try await ledger.selectedDestination(provider) {
                        try await ledger.wakeWaiting(destinationID: destination.id)
                    }
                } else { await self.recoverProvider(provider); recoveredNow = true }
                if self.backupRequested { self.requestDrain() }
                await self.establishStartupInventory()
                if recoveredNow { await self.refreshStoredSettings() }
                self.scheduleAutomaticBackup()
            } catch { await self.report(error, provider: provider) }
        }
    }
    func recoverProvider(_ provider: Provider) async {
        guard let ledger, let engine = backupEngine else { return }
        guard await engine.requestRecoveryAdmission(provider) else {
            forceRecovery.insert(provider); return
        }
        var recoveryDestination: Destination?
        do {
            recoveryDestination = try await ledger.selectedDestination(provider)
            if provider == .google {
                guard let session = googleSession else { throw SafeFailure(.invariant, domain: .core, cause: .setupUnavailable) }
                if !(await session.hasConfiguredCredential) {
                    do { try await session.loadSavedSession() }
                    catch CredentialError.notConfigured {
                        if try await ledger.selectedDestination(provider) == nil {
                            await engine.finishRecoveryAdmission(provider); return
                        }
                        throw CredentialError.notConfigured
                    }
                }
            } else {
                do { try await ensureTelegramStarted() }
                catch CredentialError.notConfigured {
                    if try await ledger.selectedDestination(provider) == nil {
                        await engine.finishRecoveryAdmission(provider); return
                    }
                    throw CredentialError.notConfigured
                }
            }
            guard allowedNetwork else { throw SafeFailure(.connectivity, domain: .core, cause: settingsState.isWiFiOnlyEnabled && network?.available == true ? .wifiRequired : .offline) }
            // Old retained mappings must settle before changing the adapter's scope
            // to the selected mapping. The adapter owns only one verified scope.
            var cursor: UUID?
            var selected: Destination?
            while true {
                let page = try await ledger.destinationInventoryPage(afterID: cursor)
                if page.isEmpty { break }
                for row in page where row.destination.provider == provider {
                    guard let binding = try await ledger.providerBinding(destinationID: row.destination.id), binding.profileID == "primary" else { throw CoreError.staleMapping }
                    if row.selected { selected = row.destination }
                    else if row.retainedTransferCount > 0 { try await recoverMapping(row.destination) }
                }
                cursor = page.last?.destination.id
            }
            if let selected {
                try await recoverMapping(selected)
                try await ledger.unblockDestination(selected.id)
            }
            providerErrors.removeValue(forKey: provider)
            if provider == .google { settingsState.googleAuthErrorMessage = nil }
            else { settingsState.telegramAuthErrorMessage = nil }
        } catch {
            let failure = ProviderSupport.safe(error, domain: provider == .google ? .google : .tdlib)
            if let destination = recoveryDestination,
               [.authentication, .accessDenied, .quota, .rateLimit].contains(failure.category) {
                do {
                    let deadline = (error as? TDLibRequestRejection)?.retryAfter ?? (error as? SafeProviderFailure)?.retryAfter
                    try await ledger.blockDestination(destination.id, failure: failure, resumeAt: deadline)
                    retryDeadlines[provider] = deadline
                    scheduleRetryDeadline(retryDeadlines.values.min())
                } catch { await report(error, provider: nil) }
            }
            if failure.cause == .operationBusy {
                forceRecovery.insert(provider)
                retryDeadlines[provider] = Date().addingTimeInterval(30)
                scheduleRetryDeadline(retryDeadlines.values.min())
            }
            await report(error, provider: provider)
        }
        await engine.finishRecoveryAdmission(provider)
    }
    func recoverMapping(_ destination: Destination) async throws {
        switch destination.provider {
        case .google:
            guard let googleAdapter else { throw CoreError.recoveryRequired }
            try await googleAdapter.recover(destination)
        case .telegram:
            guard let telegramAdapter else { throw CoreError.recoveryRequired }
            try await telegramAdapter.recover(destination)
        }
    }
    func ensureTelegramStarted() async throws {
        guard let client = tdlibClient else { throw SafeFailure(.invariant, domain: .core, cause: .setupUnavailable) }
        if await client.restartableProtocolFailure {
            guard let telegramAdapter else { throw CoreError.recoveryRequired }
            try await telegramAdapter.restartAfterProtocolFailure()
        }
        try await client.setNetworkPolicy(allowed: policyGate == nil && !pausedByUser, wifi: network?.wifi == true)
        let auth = await client.authorizationState
        if auth == .uninitialized || auth == .waitTdlibParameters {
            try await client.start()
        }
        updateTelegramAuthStep(await client.authorizationState)
    }
    func establishStartupInventory() async {
        guard !startupInventoryCompleted, !shuttingDown else { return }
        if startupInventoryRunning { startupInventoryWake = true; return }
        startupInventoryRunning = true
        defer { startupInventoryRunning = false }
        // Google and Telegram recovery can request this concurrently. Coalesce
        // them: an older attempt must not report failure after another succeeds.
        repeat {
            startupInventoryWake = false
            await performStartupInventory()
        } while startupInventoryWake && !startupInventoryCompleted && !shuttingDown
    }
    private func performStartupInventory() async {
        guard !startupInventoryCompleted, let ledger, let files = fileLeaseStore else { return }
        do {
            var inventoriedGoogle: Set<UUID> = []
            let owned = await telegramAdapter?.inventoriedInputTransfers() ?? []
            var cursor: UUID?
            while true {
                let page = try await ledger.destinationInventoryPage(afterID: cursor)
                if page.isEmpty { break }
                for row in page where row.retainedTransferCount > 0 {
                    if row.destination.provider == .google {
                        guard let googleAdapter, let engine = backupEngine,
                              try await engine.snapshot().active[.google] == nil else {
                            await recordInventoryDeferral(.google); return
                        }
                        var transferCursor: UUID?
                        while true {
                            let transfers = try await ledger.retainedTransfers(destinationID: row.destination.id, afterID: transferCursor)
                            if transfers.isEmpty { break }
                            inventoriedGoogle.formUnion(transfers.map(\.id)); transferCursor = transfers.last?.id
                        }
                        try await googleAdapter.inventoryInputs(row.destination)
                        continue
                    }
                    var transferCursor: UUID?
                    while true {
                        let transfers = try await ledger.retainedTransfers(destinationID: row.destination.id, afterID: transferCursor)
                        if transfers.isEmpty { break }
                        guard transfers.allSatisfy({ owned.contains($0.id) }) else {
                            await recordInventoryDeferral(.telegram, unmatched: transfers.filter { !owned.contains($0.id) }.count)
                            return
                        }
                        transferCursor = transfers.last?.id
                    }
                }
                cursor = page.last?.destination.id
            }
            // Recovery can finish a task and remove its durable hold during the
            // awaits above. Compare the current OS inventory, not a stale start
            // snapshot. Unmatched readers keep cleanup fenced; they are not proof
            // of an asset failure or a reason to blindly resend it.
            let googleReaders = try await googleBackground?.activeTransferIDs() ?? []
            guard googleReaders.isSubset(of: inventoriedGoogle) else {
                await recordInventoryDeferral(.google, unmatched: googleReaders.subtracting(inventoriedGoogle).count)
                return
            }
            // Google's real OS task/result inventory and the native reader
            // inventory cover every retained input before staging cleanup.
            await files.completeStartupInventory(); startupInventoryCompleted = true
            startupInventoryDeferrals.removeAll()
            if let startupInventoryFailure, systemError == startupInventoryFailure { systemError = nil }
            startupInventoryFailure = nil
        } catch {
            startupInventoryFailure = ProviderSupport.safe(error, domain: .core)
            await report(error, provider: nil)
        }
    }
    private func recordInventoryDeferral(_ provider: Provider, unmatched: Int? = nil) async {
        guard startupInventoryDeferrals.insert(provider).inserted else { return }
        do {
            try await ledger?.appendEvent(.recovery, context: EventContext(origin: provider.origin,
                diagnostic: DiagnosticDetail(stage: .startupInventory, status: .changed,
                    correlationID: UUID(), items: unmatched)), decision: .wait)
        } catch { fallback.record(ProviderSupport.safe(error, domain: .sqlite)) }
    }
    func refreshStoredSettings() async {
        guard let ledger else { return }
        var failureProvider: Provider?
        do {
            let epoch = planningEpoch
            let snapshot = try await ledger.snapshot()
            guard epoch == planningEpoch else { return }
            let g = snapshot.providers.first { $0.provider == .google }
            let t = snapshot.providers.first { $0.provider == .telegram }
            settingsState.isGoogleConnected = g?.destinationID != nil
            settingsState.isGoogleEnabled = g?.enabled ?? false
            settingsState.isTelegramConnected = t?.destinationID != nil
            settingsState.isTelegramEnabled = t?.enabled ?? false
            if settingsState.isGoogleConnected {
                do { settingsState.googleAccountEmail = try credentialStore.loadGoogleCredential(forProfile: "primary").email }
                catch { settingsState.googleAccountEmail = nil }
            } else { settingsState.googleAccountEmail = nil }
            if let client = tdlibClient {
                failureProvider = .telegram
                let auth = await client.authorizationState; updateTelegramAuthStep(auth)
                if auth == .ready {
                    let me = try await client.getMe()
                    guard epoch == planningEpoch else { return }
                    settingsState.telegramAccountName = [me["first_name"]?.stringValue, me["last_name"]?.stringValue].compactMap { $0 }.joined(separator: " ")
                    if let id = t?.destinationID, let binding = try await ledger.providerBinding(destinationID: id) {
                        struct Scope: Decodable { let chatID: Int64 }
                        let scope = try JSONDecoder().decode(Scope.self, from: binding.scope)
                        let chat = try await client.request(["@type": "getChat", "chat_id": scope.chatID])
                        guard epoch == planningEpoch else { return }
                        settingsState.telegramChatID = scope.chatID
                        settingsState.telegramChannelName = chat["title"]?.stringValue
                    }
                }
            }
            scheduleThrottledRefresh()
        } catch { await report(error, provider: failureProvider) }
    }
    func updateTelegramAuthStep(_ state: TDLibAuthorizationState) {
        switch state {
        case .uninitialized: settingsState.telegramAuthStep = .unconfigured
        case .waitTdlibParameters: settingsState.telegramAuthStep = .initializing
        case .waitPhoneNumber: settingsState.telegramAuthStep = .enterPhoneNumber
        case .waitCode: settingsState.telegramAuthStep = .enterCode
        case .waitPassword: settingsState.telegramAuthStep = .enterPassword
        case .waitEmailAddress: settingsState.telegramAuthStep = .enterEmail
        case .waitEmailCode: settingsState.telegramAuthStep = .enterEmailCode
        case .waitOtherDeviceConfirmation: settingsState.telegramAuthStep = .otherDeviceConfirmation
        case .waitRegistration: settingsState.telegramAuthStep = .registration
        case .waitPremiumPurchase: settingsState.telegramAuthStep = .premiumPurchase
        case .ready: settingsState.telegramAuthStep = settingsState.isTelegramConnected ? .connected : .readyForChannel
        case .loggingOut, .closing: settingsState.telegramAuthStep = .closing
        case .closed: settingsState.telegramAuthStep = .closed
        case .uncertain: settingsState.telegramAuthStep = .error
        }
    }
}
