import Foundation
import CloudifiedCore

extension AppEnvironment {
    public func setGoogleEnabled(_ value: Bool) { setEnabled(.google, value) }
    public func setTelegramEnabled(_ value: Bool) { setEnabled(.telegram, value) }
    func setEnabled(_ provider: Provider, _ value: Bool) {
        guard !shuttingDown else { return }
        pendingProviderEnables[provider] = (value, providerMappingRevisions[provider, default: 0])
        scheduleProviderEnableChanges()
        scheduleThrottledRefresh()
    }
    func scheduleProviderEnableChanges() {
        guard providerEnableTask == nil, bootstrapComplete, !shuttingDown,
              backgroundExpirationTask == nil, commandProvider == nil, !controlTransition,
              !settingsState.isConnectingGoogle, !settingsState.isConnectingTelegram,
              isForeground || backgroundExecutionAllowed,
              let provider = Provider.allCases.first(where: { pendingProviderEnables[$0] != nil && recoveryTasks[$0] == nil }) else { return }
        // Reserve this executor before creating the unstructured task. Further
        // taps replace one pending preference instead of racing another command.
        providerEnableTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.providerEnableTask = nil
                self.scheduleProviderEnableChanges()
            }
            guard let intent = self.pendingProviderEnables[provider],
                  intent.revision == self.providerMappingRevisions[provider, default: 0] else {
                self.pendingProviderEnables.removeValue(forKey: provider); return
            }
            do {
                guard let destination = try await self.ledger?.selectedDestination(provider) else {
                    self.pendingProviderEnables.removeValue(forKey: provider); return
                }
                try Task.checkCancellation()
                // Reads above yield. Leave the latest intent pending if another
                // action won admission; its completion schedules this executor.
                guard self.backgroundExpirationTask == nil, self.commandProvider == nil,
                      !self.controlTransition, self.recoveryTasks[provider] == nil,
                      !self.settingsState.isConnectingGoogle, !self.settingsState.isConnectingTelegram else { return }
                guard let latest = self.pendingProviderEnables.removeValue(forKey: provider),
                      latest.revision == self.providerMappingRevisions[provider, default: 0] else { return }
                let token = UUID()
                do {
                    _ = try await self.beginProviderChange(provider, token: token, requiresReleasedInputs: false)
                    defer { self.endProviderChange(token) }
                    guard try await self.ledger?.selectedDestination(provider)?.id == destination.id else { throw CoreError.staleMapping }
                    try await self.backupEngine?.setEnabled(destinationID: destination.id, enabled: latest.value)
                    if !latest.value && provider == .google { try await self.googleAdapter?.cancelOwnedTransfers() }
                    if latest.value { try await self.recoverMapping(destination) }
                    await self.refreshStoredSettings()
                } catch { self.endProviderChange(token); throw error }
            } catch {
                if !(error is CancellationError) { await self.report(error, provider: provider) }
            }
        }
    }
    public func setWiFiOnly(_ value: Bool) {
        settingsState.isWiFiOnlyEnabled = value
        UserDefaults.standard.set(value, forKey: "CloudifiedWiFiOnly")
        networkPolicy.setCellularAllowed(!value)
        schedulePolicyUpdate()
    }
    public func setPauseInLowPower(_ value: Bool) {
        settingsState.pauseInLowPower = value
        UserDefaults.standard.set(value, forKey: "CloudifiedPauseLowPower")
        schedulePolicyUpdate()
    }
    public func updateLivePhotoPolicy(_ option: LivePhotoFallbackOption) {
        guard option != settingsState.livePhotoFallback, commandProvider == nil else { return }
        Task { [weak self] in
            guard let self, let ledger = self.ledger else { return }
            let token = UUID()
            do {
                let enabled = try await self.beginProviderChange(.google, token: token)
                defer { self.endProviderChange(token) }
                if let destination = try await ledger.selectedDestination(.google) {
                    try await ledger.invalidateCurrentCoverage(destinationID: destination.id)
                    self.settingsState.livePhotoFallback = option
                    UserDefaults.standard.set(option.rawValue, forKey: "CloudifiedLivePhotoFallback")
                    // Frozen new policy + reset cursor. Alias absence already makes
                    // old smaller coverage no longer Saved; producer replans only
                    // under this new generation, even if an asset cannot prepare.
                    try await self.backupEngine?.setEnabled(destinationID: destination.id, enabled: enabled)
                } else {
                    self.settingsState.livePhotoFallback = option
                    UserDefaults.standard.set(option.rawValue, forKey: "CloudifiedLivePhotoFallback")
                }
                await self.refreshStoredSettings()
            } catch { self.endProviderChange(token); await self.report(error, provider: .google) }
        }
    }
    public func connectGoogle(oauthToken: String?) async throws {
        let token = UUID()
        let started = ProcessInfo.processInfo.systemUptime
        await trace(.googleConnect, .started, provider: .google, id: token)
        do {
            _ = try await beginProviderChange(.google, token: token)
            defer { endProviderChange(token) }
            settingsState.isConnectingGoogle = true
            defer { settingsState.isConnectingGoogle = false }
            if let failure = connectionNetworkFailure { throw failure }
            guard let session = googleSession, let adapter = googleAdapter, let ledger else {
                throw SafeFailure(.invariant, domain: .core, cause: .setupUnavailable)
            }
            if let oauthToken {
                _ = try await session.connect(oauthToken: oauthToken)
                hasPendingGoogleCredential = true
            }
            else if !(await session.hasConfiguredCredential) { try await session.loadSavedSession() }
            await trace(.googleMapping, .started, provider: .google, id: token)
            let destination = try await adapter.mapVerifiedAccount()
            await trace(.googleMapping, .succeeded, provider: .google, id: token)
            try await ledger.setEnabled(destination.id, false)
            await trace(.googleRecovery, .started, provider: .google, id: token)
            try await adapter.recover(destination)
            await trace(.googleRecovery, .succeeded, provider: .google, id: token)
            try await ledger.unblockDestination(destination.id)
            try await backupEngine?.setEnabled(destinationID: destination.id, enabled: true)
            providerErrors.removeValue(forKey: .google); settingsState.googleAuthErrorMessage = nil
            await establishStartupInventory(); await refreshStoredSettings()
            await trace(.googleConnect, .succeeded, provider: .google, id: token, started: started)
        } catch {
            await trace(.googleConnect, .failed, provider: .google, id: token, started: started,
                        failure: ProviderSupport.safe(error, domain: .google))
            endProviderChange(token); await report(error, provider: .google)
            throw ProviderSupport.safe(error, domain: .google)
        }
    }
    public func disconnectGoogle() async throws {
        let token = UUID()
        do {
            _ = try await beginProviderChange(.google, token: token)
            defer { endProviderChange(token) }
            if let destination = try await ledger?.selectedDestination(.google) { try await ledger?.deselectDestination(destination.id) }
            try await googleSession?.disconnect()
            hasPendingGoogleCredential = false
            settingsState.isGoogleConnected = false; settingsState.googleAccountEmail = nil
            await refreshStoredSettings()
        } catch { endProviderChange(token); await report(error, provider: .google); throw ProviderSupport.safe(error, domain: .google) }
    }
    public func saveTelegramAPICredentials(apiId: Int32, apiHash: String) async throws {
        let token = UUID()
        do {
            _ = try await beginProviderChange(.telegram, token: token)
            defer { endProviderChange(token) }
            settingsState.isConnectingTelegram = true
            defer { settingsState.isConnectingTelegram = false }
            // API credentials identify the application, not a Telegram account.
            if await tdlibClient?.authorizationState != .uninitialized {
                try await replaceTelegramSession()
            }
            try credentialStore.saveTelegramCredential(StoredTelegramCredential(apiId: apiId, apiHash: apiHash), forProfile: "primary")
            try await ensureTelegramStarted()
            settingsState.telegramAuthErrorMessage = nil
        } catch { endProviderChange(token); await report(error, provider: .telegram); throw ProviderSupport.safe(error, domain: .tdlib) }
    }
    func replaceTelegramSession() async throws {
        try await requireNoRetainedInputs(.telegram)
        // Do not retire observers/profile until native close really acknowledges.
        try await telegramAdapter?.close()
        let old = telegramObservers; for task in old { task.cancel() }; for task in old { await task.value }
        telegramObservers.removeAll()
        guard let ledger, let files = fileLeaseStore else { throw CoreError.recoveryRequired }
        let client = try TDLibClient(profileID: "primary", credentialStore: credentialStore, diagnosticSink: diagnosticSink)
        tdlibClient = client; telegramAdapter = TelegramProviderAdapter(client: client, ledger: ledger, files: files)
        startTelegramSubscriptions()
    }
    public func reconnectTelegram() async throws {
        let token = UUID()
        do {
            _ = try await beginProviderChange(.telegram, token: token)
            defer { endProviderChange(token) }
            if await tdlibClient?.authorizationState == .closed { try await replaceTelegramSession() }
            try await ensureTelegramStarted()
            if let destination = try await ledger?.selectedDestination(.telegram) {
                try await recoverMapping(destination)
            }
            await refreshStoredSettings()
        } catch { endProviderChange(token); await report(error, provider: .telegram); throw ProviderSupport.safe(error, domain: .tdlib) }
    }
    public func submitTelegramPhone(_ phone: String) async throws { try await telegramAuth { try await $0.setAuthenticationPhoneNumber(phone) } }
    public func submitTelegramCode(_ code: String) async throws { try await telegramAuth { try await $0.checkAuthenticationCode(code) } }
    public func submitTelegramPassword(_ password: String) async throws { try await telegramAuth { try await $0.checkAuthenticationPassword(password) } }
    public func submitTelegramEmail(_ email: String) async throws {
        try await telegramAuth { _ = try await $0.request(["@type": "setAuthenticationEmailAddress", "email_address": email]) }
    }
    public func submitTelegramEmailCode(_ code: String) async throws {
        try await telegramAuth { _ = try await $0.request(["@type": "checkAuthenticationEmailCode", "code": ["@type": "emailAddressAuthenticationCode", "code": code]]) }
    }
    func telegramAuth(_ operation: @Sendable (TDLibClient) async throws -> Void) async throws {
        guard !settingsState.isConnectingTelegram, commandProvider == nil, let client = tdlibClient else { throw CoreError.invalidTransition }
        settingsState.isConnectingTelegram = true
        defer { settingsState.isConnectingTelegram = false }
        do {
            guard allowedNetwork else { throw SafeFailure(.connectivity, domain: .tdlib, cause: .offline) }
            try await operation(client)
            updateTelegramAuthStep(await client.authorizationState)
            settingsState.telegramAuthErrorMessage = nil
        } catch { await report(error, provider: .telegram); throw ProviderSupport.safe(error, domain: .tdlib) }
    }
    public func mapTelegramChannel(chatID: Int64) async throws {
        let token = UUID()
        do {
            _ = try await beginProviderChange(.telegram, token: token)
            defer { endProviderChange(token) }
            settingsState.isConnectingTelegram = true
            defer { settingsState.isConnectingTelegram = false }
            guard let adapter = telegramAdapter, let ledger else { throw CoreError.recoveryRequired }
            let destination = try await adapter.mapVerifiedChannel(chatID: chatID)
            try await ledger.setEnabled(destination.id, false)
            try await adapter.recover(destination)
            try await ledger.unblockDestination(destination.id)
            try await backupEngine?.setEnabled(destinationID: destination.id, enabled: true)
            providerErrors.removeValue(forKey: .telegram); settingsState.telegramAuthErrorMessage = nil
            await establishStartupInventory(); await refreshStoredSettings()
        } catch { endProviderChange(token); await report(error, provider: .telegram); throw ProviderSupport.safe(error, domain: .tdlib) }
    }
    public func disconnectTelegram() async throws {
        let token = UUID()
        do {
            _ = try await beginProviderChange(.telegram, token: token)
            defer { endProviderChange(token) }
            try await replaceTelegramSession()
            if let destination = try await ledger?.selectedDestination(.telegram) { try await ledger?.deselectDestination(destination.id) }
            // App unlink retains the protected native account/database for genuine
            // same-account reconnect; it does not falsely claim Telegram logout.
            settingsState.isTelegramConnected = false; settingsState.telegramAccountName = nil
            settingsState.telegramChannelName = nil; settingsState.telegramChatID = nil
            settingsState.telegramAuthStep = .unconfigured
            await refreshStoredSettings()
        } catch { endProviderChange(token); await report(error, provider: .telegram); throw ProviderSupport.safe(error, domain: .tdlib) }
    }
    public var telegramLocalResetAvailable: Bool {
        providerErrors[.telegram]?.cause == .databaseKeyUnavailable
    }
    public func resetTelegramConnectionAfterKeyLoss() async throws {
        guard telegramLocalResetAvailable else { throw CoreError.invalidTransition }
        let token = UUID()
        await trace(.telegramLocalReset, .started, provider: .telegram, id: token)
        do {
            _ = try await beginProviderChange(.telegram, token: token)
            defer { endProviderChange(token) }
            try await replaceTelegramSession()
            try await requireNoRetainedInputs(.telegram)
            guard let client = tdlibClient else { throw CoreError.recoveryRequired }
            try await client.resetLocalDatabaseAfterKeyLoss()
            if let destination = try await ledger?.selectedDestination(.telegram) {
                try await ledger?.deselectDestination(destination.id)
            }
            providerErrors.removeValue(forKey: .telegram)
            settingsState.telegramAuthErrorMessage = nil
            settingsState.telegramAccountName = nil; settingsState.telegramChannelName = nil
            settingsState.telegramChatID = nil
            try await ensureTelegramStarted()
            await refreshStoredSettings()
            await trace(.telegramLocalReset, .succeeded, provider: .telegram, id: token)
        } catch {
            await trace(.telegramLocalReset, .failed, provider: .telegram, id: token,
                        failure: ProviderSupport.safe(error, domain: .tdlib))
            endProviderChange(token); await report(error, provider: .telegram)
            throw ProviderSupport.safe(error, domain: .tdlib)
        }
    }
    public func logoutTelegram() async throws {
        // Actual account switch is an explicit logout, never deletion of DB keys.
        let token = UUID()
        do {
            _ = try await beginProviderChange(.telegram, token: token)
            defer { endProviderChange(token) }
            guard let client = tdlibClient else { throw CoreError.recoveryRequired }
            _ = try await client.request(["@type": "logOut"])
            try await replaceTelegramSession()
            if let destination = try await ledger?.selectedDestination(.telegram) { try await ledger?.deselectDestination(destination.id) }
            settingsState.isTelegramConnected = false
            try await ensureTelegramStarted()
            await refreshStoredSettings()
        } catch { endProviderChange(token); await report(error, provider: .telegram); throw ProviderSupport.safe(error, domain: .tdlib) }
    }
}
