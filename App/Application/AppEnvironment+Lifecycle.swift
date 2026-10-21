import Foundation
import CloudifiedCore

extension AppEnvironment {
    var allowedNetwork: Bool {
        guard let network, network.available, !network.constrained else { return false }
        return !settingsState.isWiFiOnlyEnabled || (network.wifi && !network.expensive)
    }
    var policyGate: KnownCause? {
        if !isForeground && !backgroundExecutionAllowed { return .backgroundRestricted }
        if ProcessInfo.processInfo.thermalState == .critical || ProcessInfo.processInfo.thermalState == .serious { return .thermalPressure }
        if settingsState.pauseInLowPower && ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPowerMode }
        if network?.available != true { return .offline }
        if network?.constrained == true { return .lowDataMode }
        if !allowedNetwork { return .wifiRequired }
        return nil
    }
    func schedulePolicyUpdate() {
        policyDirty = true
        guard policyTask == nil, !shuttingDown else { return }
        policyTask = Task { [weak self] in
            while self?.policyDirty == true && !Task.isCancelled {
                self?.policyDirty = false
                await self?.applyPolicy()
            }
            self?.policyTask = nil
        }
    }
    func applyPolicy() async {
        guard let engine = backupEngine else { return }
        let cause = policyGate
        let facts = ExecutionPolicyFacts(foreground: isForeground, allowed: backgroundExecutionAllowed,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, intent: backupIntent, cause: cause)
        let changed = lastPolicyFacts != facts
        let detail = changed ? makeDiagnosticDetail(.networkPolicy, .changed, id: UUID()) : nil
        lastPolicyFacts = facts
        var old: KnownCause?
        do {
            old = try await engine.snapshot().systemGate
            if cause != old { try await engine.setSystemGate(cause) }
        } catch { await report(error, provider: nil) }
        // Enforce the native network gate even if SQLite/logging fails.
        do { try await tdlibClient?.setNetworkPolicy(allowed: cause == nil && !pausedByUser, wifi: network?.wifi == true) }
        catch { await report(error, provider: .telegram) }
        if cause == nil { scheduleAutomaticBackup() }
        if cause != nil {
            if let sourceProducer { _ = await sourceProducer.stop() }
        } else {
            if old != nil { requestRecovery(.google); requestRecovery(.telegram) }
            if backupRequested && (old != nil || needsWake) { requestDrain() }
        }
        // Apply cancellation/native policy before diagnostic I/O. Facts were
        // frozen above, so an await cannot relabel the original transition.
        if let detail { await recordTrace(detail) }
        scheduleThrottledRefresh()
    }
    public func applicationActive() {
        isForeground = true
        refreshNotificationPermission()
        if selectedTab == .activity {
            if visibleActivityPage == .logs && !logsState.hasLoaded { reloadLogs() }
            if visibleActivityPage == .issues && !notUploadedState.hasLoaded { reloadFailures() }
        }
        refreshPhotosAccess()
        if backupExecutionTask == nil && settingsState.automaticBackup && !pausedByUser {
            needsFreshScan = true
        }
        continuation.endGrace()
        requestRecovery(.google, force: true); requestRecovery(.telegram, force: true)
        schedulePolicyUpdate(); scheduleThrottledRefresh()
        scheduleAutomaticBackup()
        if backupRequested { requestContinuation(); requestDrain() }
        scheduleAutomaticBackground()
    }
    /// Still foreground: last chance to queue continued processing for a run
    /// whose earlier request finished or was refused.
    public func applicationWillResignActive() {
        requestContinuation()
    }
    public func applicationBackgrounded() {
        if backupRequested && !pausedByUser && !automaticBackground.allowsExecution { continuation.beginGrace() }
        isForeground = false
        scheduleAutomaticBackground()
        onMemoryPressure?()
        // Pages are disposable; durable failures/receipts remain in SQLite.
        failurePageTask?.cancel(); logPageTask?.cancel(); runPageTask?.cancel()
        failureQueryGeneration += 1; logQueryGeneration += 1
        notUploadedState.items.removeAll(); logsState.entries.removeAll()
        notUploadedState.hasLoaded = false; logsState.hasLoaded = false
        notUploadedState.isLoading = false; logsState.isLoading = false
        schedulePolicyUpdate()
    }
    public func resourcePressureChanged() { schedulePolicyUpdate(); scheduleThrottledRefresh() }
    public func memoryWarning() {
        onMemoryPressure?()
        failurePageTask?.cancel(); logPageTask?.cancel(); runPageTask?.cancel()
        failureQueryGeneration += 1; logQueryGeneration += 1
        notUploadedState.items.removeAll(); logsState.entries.removeAll()
        notUploadedState.hasLoaded = false; logsState.hasLoaded = false
        notUploadedState.isLoading = false; logsState.isLoading = false
        scheduleThrottledRefresh()
    }
    func backgroundExpired() {
        guard backgroundExpirationTask == nil else { return }
        backupRequested = false; needsWake = false
        resumeAfterExpiration = true
        retryTask?.cancel(); retryTask = nil
        let run = backupExecutionTask; run?.cancel()
        // Return the OS grants before waiting for Core, persistence or readers.
        continuation.finish(success: false)
        automaticBackground.finish(success: false)
        backgroundExpirationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.backgroundExpirationTask = nil; self.scheduleThrottledRefresh(); self.scheduleAutomaticBackup() }
            do { try await self.backupEngine?.setSystemGate(.backgroundExpired) } catch { await self.report(error, provider: nil) }
            self.dashboardState.waitingOrErrorReason = "Background time ended. Open Cloudified to continue."
            self.schedulePolicyUpdate()
            if let source = self.sourceProducer { _ = await source.stop() }
            await run?.value
            do { try await self.tdlibClient?.setNetworkPolicy(allowed: false, wifi: false) } catch { await self.report(error, provider: .telegram) }
            do {
                try await self.ledger?.appendEvent(.backgroundExpiration, context: EventContext(), decision: .reconcile,
                    severity: .warning, failure: SafeFailure(.connectivity, domain: .core, cause: .backgroundExpired))
            } catch { await self.report(error, provider: nil) }
            self.scheduleAutomaticBackground()
            self.dashboardState.waitingOrErrorReason = "Background time ended. Resume to continue safely."
            self.scheduleThrottledRefresh()
        }
    }
    func idleCleanup() async {
        guard cleanupTask == nil, commandProvider == nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performIdleCleanup()
        }
        cleanupTask = task; await task.value; cleanupTask = nil
    }
    func performIdleCleanup() async {
        guard !isScanning, planningProvider == nil, let ledger, let files = fileLeaseStore else { return }
        do {
            if startupInventoryCompleted {
                _ = try await files.sweep(limit: 20)
                _ = try await files.reclaimOrphans(limit: 20)
            }
            _ = try await ledger.pruneDiagnostics()
            var cursor: UUID?, hasHolds = false
            while true {
                let page = try await ledger.destinationInventoryPage(afterID: cursor)
                if page.isEmpty { break }
                if page.contains(where: { $0.retainedTransferCount > 0 }) { hasHolds = true; break }
                cursor = page.last?.destination.id
            }
            if !hasHolds { try await telegramAdapter?.trimIdleCache() }
            let snapshot = try await ledger.snapshot()
            if !hasHolds && retryTask == nil && !needsWake && recoveryTasks.isEmpty &&
                !snapshot.providers.contains(where: { $0.enabled && !$0.recoveryComplete }) {
                let participating = snapshot.providers.filter { $0.enabled && $0.destinationID != nil }
                let success = !participating.isEmpty && participating.allSatisfy { $0.remaining == 0 }
                continuation.finish(success: success && snapshot.scanned)
                automaticBackground.finish(success: success && snapshot.scanned)
                backupIntent = .automatic
            }
        } catch { await report(error, provider: nil) }
    }
    /// Explicit owner shutdown. Never discard an unresolved native receiver.
    public func shutdown() async {
        shuttingDown = true; backupRequested = false; needsWake = false
        pendingProviderEnables.removeAll(); providerEnableTask?.cancel()
        automaticBackground.cancelPending()
        automaticStartTask?.cancel(); retryTask?.cancel(); bootstrapTask?.cancel(); policyTask?.cancel(); libraryAccessTask?.cancel()
        refreshTask?.cancel(); cleanupTask?.cancel(); sourceStatusTask?.cancel()
        failurePageTask?.cancel(); logPageTask?.cancel(); runPageTask?.cancel()
        for task in recoveryTasks.values { task.cancel() }
        do { try await backupEngine?.pause() } catch { fallback.record(ProviderSupport.safe(error, domain: .core)) }
        if let sourceProducer { _ = await sourceProducer.stop() }
        backupExecutionTask?.cancel(); await backupExecutionTask?.value
        await backgroundExpirationTask?.value
        await providerEnableTask?.value
        await bootstrapTask?.value; await policyTask?.value; await libraryAccessTask?.value
        for task in recoveryTasks.values { await task.value }
        do { try await googleBackground?.finishWhenIdle() } catch { fallback.record(ProviderSupport.safe(error, domain: .google)) }
        do { try await telegramAdapter?.close() } catch {
            fallback.record(ProviderSupport.safe(error, domain: .tdlib))
        }
        for task in observers + telegramObservers { task.cancel() }
        for task in observers + telegramObservers { await task.value }
        observers.removeAll(); telegramObservers.removeAll()
        networkMonitor.stop(); continuation.finish(success: false)
        automaticBackground.finish(success: false)
    }
}
