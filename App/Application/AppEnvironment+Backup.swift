import Foundation
@preconcurrency import Photos
import CloudifiedCore

extension AppEnvironment {
    public func setAutomaticBackup(_ enabled: Bool) {
        settingsState.automaticBackup = enabled
        UserDefaults.standard.set(enabled, forKey: "CloudifiedAutomaticBackup")
        if enabled { scheduleAutomaticBackup() }
        scheduleAutomaticBackground()
        if !enabled, automaticBackground.ownsTask {
            if !isForeground && !continuation.allowsBackgroundExecution { backgroundExpired() }
            else { automaticBackground.finish(success: false) }
        }
    }
    public func setNotifications(_ enabled: Bool) {
        notificationPreferenceRevision &+= 1
        let revision = notificationPreferenceRevision
        settingsState.notificationsEnabled = enabled; settingsState.notificationsRefused = false
        Task { [weak self] in
            let stored = await BackupNotifications.setEnabled(enabled)
            guard let self, self.notificationPreferenceRevision == revision else { return }
            self.settingsState.notificationsEnabled = stored
            self.settingsState.notificationsRefused = enabled && !stored
        }
    }
    func refreshNotificationPermission() {
        let revision = notificationPreferenceRevision
        Task { [weak self] in
            let permission = await BackupNotifications.currentPermission()
            guard let self, self.notificationPreferenceRevision == revision, !self.shuttingDown else { return }
            self.settingsState.notificationsEnabled = permission.enabled
            self.settingsState.notificationsRefused = permission.refused
        }
    }
    func scheduleAutomaticBackup() {
        guard settingsState.automaticBackup, isForeground, bootstrapComplete,
              !pausedByUser, !shuttingDown, automaticStartTask == nil else { return }
        automaticStartTask = Task { [weak self] in
            guard let self else { return }
            defer { self.automaticStartTask = nil }
            guard let snapshot = try? await self.ledger?.snapshot(),
                  snapshot.providers.contains(where: { $0.enabled && $0.destinationID != nil }),
                  self.settingsState.automaticBackup, self.isForeground, !self.pausedByUser, !self.shuttingDown,
                  self.backgroundExpirationTask == nil, self.commandProvider == nil,
                  !self.controlTransition, self.libraryAccessTask == nil else { return }
            guard !self.backupRequested else { return }
            self.resumeBackup(intent: .automatic)
        }
    }
    /// Every foreground run asks for continued processing, automatic or not.
    /// BackupContinuation ignores the call while a request is queued or running.
    func requestContinuation() {
        guard isForeground, backupRequested, !pausedByUser, !shuttingDown, backgroundExpirationTask == nil else { return }
        // Items that used all three attempts stay in remaining; they are not work.
        let actionable = [dashboardState.googleStatus, dashboardState.telegramStatus].contains { status in
            status.isEnabled && status.isConnected && (status.remainingCount.map { $0 - (status.failedCount ?? 0) > 0 } ?? true)
        }
        guard needsFreshScan || dashboardState.accessibleLibraryTotal == nil || actionable else { return }
        do { try continuation.request() }
        catch { fallback.record(ProviderSupport.safe(error, domain: .core)) }
    }

    /// Local permission/metadata setup is independent of credentials and network policy.
    public func requestPhotoLibraryAccess() {
        guard isForeground, bootstrapComplete, !shuttingDown, backgroundExpirationTask == nil, commandProvider == nil,
              !controlTransition, backupExecutionTask == nil, libraryAccessTask == nil else { return }
        controlTransition = true; isScanning = true; systemError = nil
        dashboardState.isReadingLibrary = true
        scheduleThrottledRefresh()
        libraryAccessTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.isScanning = false; self.controlTransition = false
                self.dashboardState.isReadingLibrary = false; self.libraryAccessTask = nil
                self.scheduleThrottledRefresh()
                if self.backupRequested { self.requestDrain() }
            }
            do {
                var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
                self.refreshPhotosAccess()
                try Task.checkCancellation()
                guard status == .authorized || status == .limited else {
                    throw SafeFailure(.accessDenied, domain: .photos, cause: .permissionDenied)
                }
                guard let pipeline = self.photoPipeline else { throw CoreError.recoveryRequired }
                self.scanProgress = nil
                let scan = try await pipeline.scanLibrary(full: true, progress: self.scanProgressSink)
                self.activeScanID = scan.scanID; self.planningCursors.removeAll()
                self.needsFreshScan = false
            } catch {
                if !(error is CancellationError) { await self.report(error, provider: nil) }
            }
        }
    }
    public func requestBackup() {
        guard !shuttingDown, backgroundExpirationTask == nil, commandProvider == nil, !controlTransition else { return }
        if backupExecutionTask != nil {
            backupIntent = .explicit
            requestContinuation()
            schedulePolicyUpdate(); scheduleThrottledRefresh(); requestDrain()
            return
        }
        controlTransition = true; systemError = nil
        backupRequested = true; needsFreshScan = true; pausedByUser = false; resumeAfterExpiration = false
        backupIntent = .explicit
        UserDefaults.standard.set(false, forKey: "CloudifiedUserPaused")
        requestContinuation()
        Task { [weak self] in
            do { try await self?.backupEngine?.resume() } catch { await self?.report(error, provider: nil) }
            self?.controlTransition = false
            self?.schedulePolicyUpdate(); self?.requestDrain()
        }
    }
    func requestDrain() {
        needsWake = true
        if backupRequested && !pausedByUser && commandProvider == nil && backupExecutionTask != nil {
            Task { [weak self] in await self?.backupEngine?.wakeReadyLanes() }
        }
        guard backupRequested, !pausedByUser, bootstrapComplete, commandProvider == nil,
              backupExecutionTask == nil, libraryAccessTask == nil, !shuttingDown else { return }
        backupExecutionTask = Task { [weak self] in await self?.drain() }
    }
    func drain() async {
        let epoch = planningEpoch
        needsWake = false
        defer {
            isScanning = false; planningProvider = nil
            sourceStatusTask?.cancel(); sourceStatusTask = nil
            sourceProducer = nil; backupExecutionTask = nil
            scheduleThrottledRefresh()
            if needsWake && backupRequested && commandProvider == nil { requestDrain() }
        }
        guard let engine = backupEngine, let ledger, let pipeline = photoPipeline else { return }
        do {
            let before = try await engine.snapshot()
            guard !before.paused, before.systemGate == nil else { return }
            var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if authorization == .notDetermined {
                guard isForeground else { throw SafeFailure(.accessDenied, domain: .photos, cause: .permissionDenied) }
                authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            guard authorization == .authorized || authorization == .limited else {
                throw SafeFailure(.accessDenied, domain: .photos, cause: .permissionDenied)
            }
            let storedScan = try await ledger.currentLibraryScan()
            if needsFreshScan || storedScan?.complete != true {
                needsFreshScan = false; isScanning = true; scanProgress = nil
                let scan = try await pipeline.scanLibrary(full: false, progress: scanProgressSink)
                let retrySources = try await ledger.hasRetryableSourceFailures()
                if activeScanID != scan.scanID || retrySources { planningCursors.removeAll() }
                activeScanID = scan.scanID; isScanning = false; scanProgress = nil
            } else { activeScanID = try await ledger.currentLibraryScan()?.id }
            try Task.checkCancellation()
            guard commandProvider == nil, epoch == planningEpoch, let scanID = activeScanID else { return }
            retryDeadlines.removeAll()
            var destinations: [Destination] = [], adapters: [any ProviderAdapter] = []
            for provider in Provider.allCases {
                guard let destination = try await ledger.selectedDestination(provider), before.ledger.providers.first(where: { $0.provider == provider }).map({ $0.enabled && $0.recoveryComplete }) == true else { continue }
                if provider == .google, let googleAdapter { adapters.append(googleAdapter); destinations.append(destination) }
                if provider == .telegram, let telegramAdapter { adapters.append(telegramAdapter); destinations.append(destination) }
            }
            for provider in Provider.allCases {
                if let destination = try await ledger.selectedDestination(provider) {
                    retryDeadlines[provider] = try await ledger.nextWake(destinationID: destination.id)
                }
            }
            scheduleRetryDeadline(retryDeadlines.values.min())
            guard !adapters.isEmpty else { await idleCleanup(); return }
            let source = DemandSourceProducer(scanID: scanID, pipeline: pipeline, destinations: destinations,
                policy: settingsState.livePhotoFallback, cursors: planningCursors)
            sourceProducer = source
            let events = source.statusEvents
            sourceStatusTask = Task { [weak self] in
                for await provider in events { self?.planningProvider = provider; self?.scheduleThrottledRefresh() }
            }
            let results = try await engine.runReadyBatch(adapters: adapters, preparer: pipeline.originalPreparer, source: source) { [weak self] result in
                await self?.laneEnded(result)
            }
            let positions = await source.stop()
            if epoch == planningEpoch { planningCursors = positions }
            for result in results {
                if let failure = result.failure { await report(failure, provider: result.provider) }
            }
            scheduleRetryDeadline(retryDeadlines.values.min())
            planningProvider = nil
            await idleCleanup()
        } catch {
            if let sourceProducer { _ = await sourceProducer.stop() }
            if !(error is CancellationError) { await report(error, provider: nil) }
        }
    }
    public func requestPause() {
        guard !shuttingDown, backgroundExpirationTask == nil, !controlTransition else { return }
        controlTransition = true
        backupRequested = false; needsWake = false; pausedByUser = true
        automaticBackground.cancelPending()
        UserDefaults.standard.set(true, forKey: "CloudifiedUserPaused")
        retryTask?.cancel(); retryTask = nil
        scheduleThrottledRefresh()
        Task { [weak self] in
            guard let self else { return }
            defer { self.controlTransition = false; self.scheduleThrottledRefresh() }
            do { try await self.backupEngine?.pause() } catch { await self.report(error, provider: nil) }
            do { try await self.tdlibClient?.setNetworkPolicy(allowed: false, wifi: false) } catch { await self.report(error, provider: .telegram) }
            do { try await self.googleAdapter?.cancelOwnedTransfers() } catch { await self.report(error, provider: .google) }
            if let source = self.sourceProducer { _ = await source.stop() }
            let run = self.backupExecutionTask; run?.cancel(); await run?.value
            self.continuation.finish(success: false)
            self.automaticBackground.finish(success: false)
            self.schedulePolicyUpdate(); self.scheduleThrottledRefresh()
        }
    }
    public func requestResume() {
        resumeBackup(intent: .explicit)
    }
    func resumeBackup(intent: DiagnosticBackupIntent) {
        guard !shuttingDown, backgroundExpirationTask == nil, commandProvider == nil, !controlTransition else { return }
        controlTransition = true
        systemError = nil; pausedByUser = false; backupRequested = true; resumeAfterExpiration = false
        backupIntent = intent
        UserDefaults.standard.set(false, forKey: "CloudifiedUserPaused")
        requestContinuation()
        scheduleThrottledRefresh()
        Task { [weak self] in
            guard let self else { return }
            defer { self.controlTransition = false; self.scheduleThrottledRefresh() }
            _ = await self.backupEngine?.requestRecoveryAdmission(.telegram)
            do { try await self.backupEngine?.resume() } catch { await self.report(error, provider: nil) }
            self.requestRecovery(.google, force: true)
            self.requestDrain()
            do {
                try await self.tdlibClient?.setNetworkPolicy(allowed: self.allowedNetwork && self.policyGate == nil,
                                                           wifi: self.network?.wifi == true)
            } catch { await self.report(error, provider: .telegram) }
            self.requestRecovery(.telegram, force: true)
            self.schedulePolicyUpdate()
        }
    }
    func laneEnded(_ result: LaneResult) {
        if result.requiresRecovery || forceRecovery.contains(result.provider) { requestRecovery(result.provider, force: true) }
        retryDeadlines[result.provider] = result.nextWake
        scheduleRetryDeadline(retryDeadlines.values.min())
        scheduleThrottledRefresh()
    }
    func scheduleRetryDeadline(_ date: Date?) {
        retryTask?.cancel(); retryTask = nil
        guard let date, backupRequested else { return }
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow))) } catch { return }
            self?.retryTask = nil
            self?.retryDeadlines = self?.retryDeadlines.filter { $0.value > Date() } ?? [:]
            self?.requestDrain()
        }
    }
    /// Freeze/join the sole planner BEFORE any identity/coverage mutation.
    /// The healthy lane finishes its current ready work without cancellation.
    func beginProviderChange(_ provider: Provider, token: UUID, requiresReleasedInputs: Bool = true) async throws -> Bool {
        guard backgroundExpirationTask == nil, commandProvider == nil, !controlTransition, bootstrapComplete, !settingsState.isConnectingTelegram, !settingsState.isConnectingGoogle, recoveryTasks[provider] == nil else { throw CoreError.invalidTransition }
        commandProvider = provider; commandID = token; planningEpoch += 1
        if provider == .google { settingsState.isSettlingGoogle = true }
        else { settingsState.isSettlingTelegram = true }
        await cleanupTask?.value
        if let destination = try await ledger?.selectedDestination(provider) {
            let enabled = try await ledger?.snapshot().providers.first { $0.destinationID == destination.id }?.enabled ?? false
            try await backupEngine?.setEnabled(destinationID: destination.id, enabled: false)
            if let source = sourceProducer { _ = await source.stop() }
            _ = await backupEngine?.settleProvider(provider)
            // Include old deselected mappings using this profile, not just UI selection.
            if requiresReleasedInputs { try await requireNoRetainedInputs(provider) }
            planningCursors.removeAll()
            return enabled
        }
        if let source = sourceProducer { _ = await source.stop() }
        if requiresReleasedInputs { try await requireNoRetainedInputs(provider) }
        planningCursors.removeAll()
        return false
    }
    func endProviderChange(_ token: UUID) {
        guard commandID == token else { return }
        commandID = nil
        settingsState.isSettlingGoogle = false; settingsState.isSettlingTelegram = false
        commandProvider = nil; scheduleThrottledRefresh()
        let recovery = recoveryWake; recoveryWake.removeAll()
        for provider in recovery { requestRecovery(provider) }
        if backupRequested { requestDrain() }
        scheduleAutomaticBackup()
        scheduleAutomaticBackground()
    }
    func requireNoRetainedInputs(_ provider: Provider) async throws {
        guard let ledger else { throw CoreError.recoveryRequired }
        var cursor: UUID?
        while true {
            let page = try await ledger.destinationInventoryPage(afterID: cursor)
            if page.isEmpty { break }
            for row in page where row.destination.provider == provider {
                guard row.retainedTransferCount == 0 else {
                    throw SafeFailure(.reconciliation, domain: provider == .google ? .google : .tdlib, cause: .outcomeUnknown)
                }
            }
            cursor = page.last?.destination.id
        }
    }
    public func retryItem(_ item: NotUploadedItem) {
        guard item.canRetry, commandProvider == nil else { return }
        Task { [weak self] in
            guard let self, let ledger = self.ledger else { return }
            let provider: Provider = item.provider == "Google Photos" ? .google : .telegram
            let token = UUID()
            do {
                let enabled = try await self.beginProviderChange(provider, token: token, requiresReleasedInputs: false)
                defer { self.endProviderChange(token) }
                guard let destination = try await ledger.selectedDestination(provider), destination.id == item.destinationID else { throw CoreError.staleMapping }
                if let jobID = item.jobID { try await ledger.explicitRetry(jobID: jobID) }
                else if let asset = item.sourceAsset {
                    if let job = try await ledger.aliasedJob(assetID: asset.id, destinationID: destination.id), try await ledger.hasRetainedTransfers(jobID: job.id) {
                        throw SafeFailure(.reconciliation, domain: provider == .google ? .google : .tdlib, cause: .outcomeUnknown)
                    }
                    try await self.photoPipeline?.planAsset(asset: asset,
                        googleDestination: provider == .google ? destination : nil,
                        telegramDestination: provider == .telegram ? destination : nil,
                        googleLiveFallback: self.settingsState.livePhotoFallback)
                    if let job = try await ledger.aliasedJob(assetID: asset.id, destinationID: destination.id), [.failed, .waiting, .reconciling, .delayed].contains(job.state) {
                        try await ledger.explicitRetry(jobID: job.id)
                    }
                }
                try await self.backupEngine?.setEnabled(destinationID: destination.id, enabled: enabled)
                self.reloadFailures()
            } catch { self.endProviderChange(token); await self.report(error, provider: provider) }
        }
    }
    public func recoverItem(_ item: NotUploadedItem) {
        guard commandProvider == nil else { return }
        Task { [weak self] in
            guard let self, let ledger = self.ledger else { return }
            let provider: Provider = item.provider == "Google Photos" ? .google : .telegram
            let token = UUID()
            do {
                let enabled = try await self.beginProviderChange(provider, token: token, requiresReleasedInputs: false)
                defer { self.endProviderChange(token) }
                guard let destination = try await ledger.selectedDestination(provider), destination.id == item.destinationID else { throw CoreError.staleMapping }
                try await self.recoverMapping(destination)
                try await ledger.unblockDestination(destination.id)
                try await self.backupEngine?.setEnabled(destinationID: destination.id, enabled: enabled)
                await self.establishStartupInventory(); self.reloadFailures()
            } catch { self.endProviderChange(token); await self.report(error, provider: provider) }
        }
    }
}
