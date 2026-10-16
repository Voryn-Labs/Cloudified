import Foundation
import CloudifiedCore

struct ExecutionPolicyFacts: Equatable {
    let foreground: Bool
    let allowed: Bool
    let lowPower: Bool
    let intent: DiagnosticBackupIntent
    let cause: KnownCause?
}

extension AppEnvironment {
    var backgroundExecutionAllowed: Bool {
        continuation.allowsBackgroundExecution || automaticBackground.allowsExecution
    }
    var backgroundSummary: String {
        if continuation.state == .running { return continuation.summary }
        if automaticBackground.allowsExecution { return automaticBackground.summary }
        if continuation.state == .requested || backupIntent == .explicit {
            return continuation.summary
        }
        return settingsState.automaticBackup ? automaticBackground.summary : "Automatic background backup is off"
    }
    func configureAutomaticBackground() {
        automaticBackground.onTrace = { [weak self] status, failure, event, id in
            guard let self else { return }
            self.recordBackgroundSaved(id: id, event: event)
            let detail = self.makeDiagnosticDetail(.automaticBackground, status, id: id, backgroundEvent: event)
            Task { @MainActor [weak self] in await self?.recordTrace(detail, failure: failure) }
        }
        automaticBackground.onChange = { [weak self] in
            self?.schedulePolicyUpdate(); self?.scheduleThrottledRefresh()
        }
        automaticBackground.onLaunch = { [weak self] in self?.automaticBackgroundGranted() }
        automaticBackground.onExpiration = { [weak self] in
            guard let self else { return }
            // Expiration of one grant cannot cancel work covered by foreground
            // execution or the independent explicit continued-processing grant.
            if self.isForeground || self.continuation.allowsBackgroundExecution {
                self.automaticBackground.finish(success: false)
                self.scheduleAutomaticBackground()
            } else { self.backgroundExpired() }
        }
        automaticBackground.register()
        automaticBackground.deliverPending()
    }
    func scheduleAutomaticBackground() {
        guard settingsState.automaticBackup, !pausedByUser, !shuttingDown else {
            automaticBackground.cancelPending(); return
        }
        let connected = (settingsState.isGoogleEnabled && settingsState.isGoogleConnected) ||
            (settingsState.isTelegramEnabled && settingsState.isTelegramConnected)
        if connected { automaticBackground.schedule() }
        else { automaticBackground.cancelPending() }
    }
    func automaticBackgroundGranted() {
        guard automaticBackground.allowsExecution, settingsState.automaticBackup, !pausedByUser, !shuttingDown,
              !controlTransition, commandProvider == nil, backgroundExpirationTask == nil,
              currentPhotosAccess.canRead else {
            automaticBackground.finish(success: false); return
        }
        continuation.endGrace()
        // A warm process can still have backupRequested set after an earlier
        // completed drain. A new opportunity must discover new library assets,
        // retaining planning cursors only if incremental scanning finds no changes.
        if backupExecutionTask == nil && libraryAccessTask == nil {
            needsFreshScan = true
            if continuation.state != .running && continuation.state != .requested { backupIntent = .automatic }
        }
        // No authorization prompts from an OS-launched background task. Bootstrap
        // verifies stored mappings and inventories real readers before draining.
        if !backupRequested {
            resumeBackup(intent: .automatic)
        } else {
            schedulePolicyUpdate(); requestDrain()
        }
        scheduleAutomaticBackground()
    }
    /// iOS relaunched or resumed the app because Google background uploads
    /// finished. A short grace window lets recovery confirm the finished file and
    /// the drain hand iOS the next one before the app is suspended again.
    public func backgroundTransferWake() {
        guard !isForeground, !pausedByUser, !shuttingDown, backgroundExpirationTask == nil,
              settingsState.automaticBackup || backupRequested else { return }
        transferWakePending = true
        if !backgroundExecutionAllowed { continuation.beginGrace() }
        let id = UUID()
        let detail = makeDiagnosticDetail(.backgroundContinuation, backgroundExecutionAllowed ? .started : .changed,
                                          id: id, backgroundEvent: .transferWake)
        Task { @MainActor [weak self] in await self?.recordTrace(detail, failure: nil) }
        guard bootstrapComplete else { return }
        consumeTransferWake()
    }
    func consumeTransferWake() {
        guard transferWakePending else { return }
        transferWakePending = false
        guard backgroundExecutionAllowed, !isForeground, !pausedByUser, !shuttingDown,
              backgroundExpirationTask == nil else { return }
        // The window is about 30 s: use the complete scan rather than rescan.
        // Drain still scans when no complete scan exists.
        needsFreshScan = false
        schedulePolicyUpdate()
        requestRecovery(.google, force: true)
        guard commandProvider == nil, !controlTransition, currentPhotosAccess.canRead else { return }
        if backupRequested { requestDrain() } else { resumeBackup(intent: .automatic) }
    }
    /// Best effort: the start count is read while the grant is new, the end
    /// count after the journal has already closed the run synchronously.
    func recordBackgroundSaved(id: UUID, event: DiagnosticBackgroundEvent) {
        let atEnd: Bool
        switch event {
        case .granted: atEnd = false
        case .completed, .endedIncomplete, .systemExpired: atEnd = true
        default: return
        }
        Task { @MainActor [weak self] in
            guard let snapshot = try? await self?.ledger?.snapshot() else { return }
            let saved = snapshot.providers.filter { $0.destinationID != nil }.compactMap(\.confirmed).reduce(0, +)
            BackgroundRunJournal.recordSaved(id: id, count: saved, atEnd: atEnd)
            if atEnd, self?.isForeground == false, let run = BackgroundRunJournal.last, run.id == id {
                BackupNotifications.runEnded(run, providers: snapshot.providers)
            }
            self?.scheduleThrottledRefresh()
        }
    }
    public func acknowledgeInterruptedRun() {
        BackgroundRunJournal.acknowledge()
        dashboardState.interruptedRunNotice = nil
        scheduleThrottledRefresh()
    }
    var scanProgressSink: @Sendable (Int, Int) -> Void {
        { [weak self] done, total in
            Task { @MainActor [weak self] in self?.scanProgressChanged(done, of: total) }
        }
    }
    func scanProgressChanged(_ done: Int, of total: Int) {
        guard isScanning else { return }
        scanProgress = (max(done, scanProgress?.done ?? 0), total)
        scheduleThrottledRefresh()
    }
}
