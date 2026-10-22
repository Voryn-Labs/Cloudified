import Foundation
import Combine
import UIKit
@preconcurrency import Photos
import CloudifiedCore

public enum AppTab: Hashable, Sendable { case dashboard, activity, settings }
enum ActivityPage: Hashable { case overview, issues, logs }
typealias DiagnosticSink = @Sendable (EventOperation, EventContext, EventDecision, EventSeverity, SafeFailure?, TimeInterval?, Int64?, Int64?) async throws -> Void

/// Composition and task ownership. Commands, snapshots and bounded page queries
/// live in focused extensions; SQLite/attempt/receipt ownership remains in Core.
@MainActor
public final class AppEnvironment: ObservableObject {
    static let shared = AppEnvironment()
    @Published public var selectedTab: AppTab = .dashboard
    // Only a visible diagnostics page should refill its disposable data after
    // memory pressure or returning from the background.
    @Published var visibleActivityPage: ActivityPage = .overview
    public let dashboardPresentation = ScreenStateStore(DashboardViewState())
    public var dashboardState: DashboardViewState {
        get { dashboardPresentation.value }
        set { dashboardPresentation.value = newValue }
    }
    public let issuesPresentation = ScreenStateStore(NotUploadedViewState())
    public var notUploadedState: NotUploadedViewState {
        get { issuesPresentation.value }
        set { issuesPresentation.value = newValue }
    }
    public let logsPresentation = ScreenStateStore(LogsViewState())
    public var logsState: LogsViewState {
        get { logsPresentation.value }
        set { logsPresentation.value = newValue }
    }
    public let settingsPresentation = ScreenStateStore(SettingsViewState())
    public var settingsState: SettingsViewState {
        get { settingsPresentation.value }
        set { settingsPresentation.value = newValue }
    }
    public let activityPresentation = ScreenStateStore(ActivityOverviewState())
    @Published var activityFailureCount: Int?
    public let storageLayout: StorageLayout?
    public let ledger: Ledger?
    public let fileLeaseStore: FileLeaseStore?
    public let photoPipeline: PhotoLibraryPipeline?
    public let backupEngine: BackupEngine?
    let credentialStore = KeychainCredentialStore()
    let networkPolicy = UploadRequestNetworkPolicy()
    let fallback = DiagnosticFallback()
    let networkMonitor = NetworkPolicyMonitor()
    let continuation = BackupContinuation()
    let automaticBackground = AutomaticBackupScheduler.shared
    var backupIntent: DiagnosticBackupIntent = .automatic
    var lastPolicyFacts: ExecutionPolicyFacts?
    let diagnosticSink: DiagnosticSink
    let exportStore: DiagnosticExportStore?
    let reportUploader = DiagnosticReportUploader()
    @Published var hasPendingGoogleCredential = false
    let googleBackground: BackgroundFileUploadTransport?
    let googleSession: GooglePhotosClientSession?
    let googleAdapter: GooglePhotosProviderAdapter?
    var tdlibClient: TDLibClient?
    var telegramAdapter: TelegramProviderAdapter?

    var observers: [Task<Void, Never>] = []
    var telegramObservers: [Task<Void, Never>] = []
    var automaticStartTask: Task<Void, Never>?
    var forceRecovery: Set<Provider> = []
    var bootstrapTask: Task<Void, Never>?
    var backupExecutionTask: Task<Void, Never>?
    var libraryAccessTask: Task<Void, Never>?
    var refreshTask: Task<Void, Never>?
    var backgroundExpirationTask: Task<Void, Never>?
    var policyTask: Task<Void, Never>?
    var retryTask: Task<Void, Never>?
    var cleanupTask: Task<Void, Never>?
    var failurePageTask: Task<Void, Never>?
    var logPageTask: Task<Void, Never>?
    var runPageTask: Task<Void, Never>?
    var sourceStatusTask: Task<Void, Never>?
    var recoveryWake: Set<Provider> = []
    var recoveryTasks: [Provider: Task<Void, Never>] = [:]
    var sourceProducer: DemandSourceProducer?
    var planningCursors: [UUID: Int64] = [:]
    var planningEpoch = 0
    var activeScanID: UUID?
    var pendingRefresh = false
    var policyDirty = false
    var bootstrapComplete = false
    var isScanning = false
    var scanProgress: (done: Int, total: Int)?
    var planningProvider: Provider?
    var backupRequested = false
    var resumeAfterExpiration = false
    var needsWake = false
    var retryDeadlines: [Provider: Date] = [:]
    var needsFreshScan = false
    var notificationPreferenceRevision: UInt64 = 0
    var startupInventoryDeferrals: Set<Provider> = []
    var transferWakePending = false
    var pausedByUser = UserDefaults.standard.bool(forKey: "CloudifiedUserPaused")
    var commandProvider: Provider?
    var commandID: UUID?
    var providerEnableTask: Task<Void, Never>?
    var pendingProviderEnables: [Provider: (value: Bool, revision: UInt64)] = [:]
    var providerMappingRevisions: [Provider: UInt64] = [:]
    var mappingCommand: Provider?
    var controlTransition = false
    var startupInventoryRunning = false
    var startupInventoryWake = false
    var startupInventoryFailure: SafeFailure?
    var systemError: SafeFailure?
    var providerErrors: [Provider: SafeFailure] = [:]
    var startupInventoryCompleted = false
    var network: NetworkPolicySnapshot?
    var isForeground = UIApplication.shared.applicationState == .active
    var shuttingDown = false
    var onMemoryPressure: (@MainActor () -> Void)?
    var failureQueryGeneration = 0
    var logQueryGeneration = 0
    var failureCursor: Int64?
    var sourceFailureCursor: Int64?
    var failurePageHistory: [(Int64?, Int64?)] = []
    var logPageHistory: [Int64?] = []
    var logCursor: Int64?
    var runCursor: Date?
    var nextFailureCursor: Int64?
    var nextSourceFailureCursor: Int64?
    var nextLogCursor: Int64?

    public init() {
        let safeFallback = fallback
        var layoutValue: StorageLayout?, ledgerValue: Ledger?, filesValue: FileLeaseStore?
        var pipelineValue: PhotoLibraryPipeline?, engineValue: BackupEngine?
        var exportValue: DiagnosticExportStore?, googleValue: GooglePhotosClientSession?
        var googleAdapterValue: GooglePhotosProviderAdapter?, telegramValue: TDLibClient?
        var telegramAdapterValue: TelegramProviderAdapter?
        var backgroundValue: BackgroundFileUploadTransport?
        var initialAttentionReason: String? = nil
        var sink: DiagnosticSink = { _, _, _, _, failure, _, _, _ in
            safeFallback.record(failure ?? SafeFailure(.invariant, domain: .sqlite, cause: .persistenceFailed))
            throw CoreError.recoveryRequired
        }
        do {
            let layout = try StorageLayout()
            let bundle = Bundle.main
            let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unavailable"
            let revision = bundle.object(forInfoDictionaryKey: "CloudifiedRevision") as? String ?? "unknown"
            let led = try Ledger(databaseURL: layout.databaseURL, version: version,
                                 revision: revision.contains("$(") ? "unknown" : revision)
            let files = try FileLeaseStore(root: layout.stagingURL, ledger: led)
            sink = { op, context, decision, severity, failure, duration, bytes, expected in
                do {
                    try await led.appendEvent(op, context: context, decision: decision, severity: severity,
                        failure: failure, duration: duration, bytes: bytes, expectedBytes: expected)
                } catch {
                    safeFallback.record(ProviderSupport.safe(error, domain: .sqlite)); throw error
                }
            }
            let background = try BackgroundFileUploadTransport(root: layout.rootDirectory)
            backgroundValue = background
            let google = try GooglePhotosClientSession(profileID: "primary", credentialStore: credentialStore,
                                                       transport: background, networkPolicy: networkPolicy, diagnosticSink: sink)
            let telegram = try TDLibClient(profileID: "primary", credentialStore: credentialStore, diagnosticSink: sink)
            layoutValue = layout; ledgerValue = led; filesValue = files
            pipelineValue = PhotoLibraryPipeline(ledger: led, fileStore: files, storageLayout: layout,
                onDiagnosticFailure: { safeFallback.record($0) })
            engineValue = BackupEngine(ledger: led, files: files, onDiagnosticFailure: { safeFallback.record($0) })
            googleValue = google; googleAdapterValue = GooglePhotosProviderAdapter(session: google, ledger: led, files: files, background: background, catalogURL: layout.rootDirectory.appendingPathComponent("google-metadata.sqlite"))
            telegramValue = telegram; telegramAdapterValue = TelegramProviderAdapter(client: telegram, ledger: led, files: files)
            // A diagnostic export failure must never remove both provider clients.
            do { exportValue = try DiagnosticExportStore(layout: layout) }
            catch { safeFallback.record(ProviderSupport.safe(error, domain: .fileSystem)) }
        } catch {
            let safe = ProviderSupport.safe(error, domain: .core); safeFallback.record(safe)
            initialAttentionReason = safe.description
        }
        storageLayout = layoutValue; ledger = ledgerValue; fileLeaseStore = filesValue
        photoPipeline = pipelineValue; backupEngine = engineValue; exportStore = exportValue
        googleBackground = backgroundValue; googleSession = googleValue; googleAdapter = googleAdapterValue
        tdlibClient = telegramValue; telegramAdapter = telegramAdapterValue; diagnosticSink = sink
        hasPendingGoogleCredential = (try? credentialStore.loadGoogleCredential(forProfile: "primary")) != nil
        if let initialAttentionReason {
            dashboardState.overallState = .needsAttention(reason: initialAttentionReason)
        }
        if let raw = UserDefaults.standard.string(forKey: "CloudifiedLivePhotoFallback"),
           let value = LivePhotoFallbackOption(rawValue: raw) { settingsState.livePhotoFallback = value }
        if UserDefaults.standard.object(forKey: "CloudifiedWiFiOnly") != nil {
            settingsState.isWiFiOnlyEnabled = UserDefaults.standard.bool(forKey: "CloudifiedWiFiOnly")
        }
        settingsState.automaticBackup = UserDefaults.standard.object(forKey: "CloudifiedAutomaticBackup") == nil || UserDefaults.standard.bool(forKey: "CloudifiedAutomaticBackup")
        settingsState.notificationsEnabled = BackupNotifications.enabled
        settingsState.pauseInLowPower = UserDefaults.standard.bool(forKey: "CloudifiedPauseLowPower")
        networkPolicy.setCellularAllowed(!settingsState.isWiFiOnlyEnabled)
        continuation.onChange = { [weak self] in self?.schedulePolicyUpdate(); self?.scheduleThrottledRefresh() }
        continuation.onTrace = { [weak self] status, failure, event in
            guard let self else { return }
            self.recordBackgroundSaved(id: self.continuation.diagnosticID, event: event)
            let detail = self.makeDiagnosticDetail(.backgroundContinuation, status,
                id: self.continuation.diagnosticID, backgroundEvent: event)
            Task { @MainActor [weak self] in await self?.recordTrace(detail, failure: failure) }
        }
        continuation.onExpiration = { [weak self] in self?.backgroundExpired() }
        startSubscriptions(); startTelegramSubscriptions()
        bootstrapTask = Task { [weak self] in await self?.bootstrap() }
        configureAutomaticBackground()
    }
    deinit {
        for task in observers + telegramObservers { task.cancel() }
        automaticStartTask?.cancel(); bootstrapTask?.cancel(); backupExecutionTask?.cancel(); libraryAccessTask?.cancel(); refreshTask?.cancel()
        backgroundExpirationTask?.cancel(); providerEnableTask?.cancel()
        policyTask?.cancel(); retryTask?.cancel(); cleanupTask?.cancel(); sourceStatusTask?.cancel()
        for task in recoveryTasks.values { task.cancel() }
        failurePageTask?.cancel(); logPageTask?.cancel(); runPageTask?.cancel()
        networkMonitor.stop()
    }
    func bootstrap() async {
        let id = UUID(), started = ProcessInfo.processInfo.systemUptime
        await trace(.startup, .started, id: id)
        do {
            try await exportStore?.removeStale()
            if pausedByUser { try await backupEngine?.pause() }
        } catch { await report(error, provider: nil) }
        await establishStartupInventory()
        // Readiness belongs to each destination. A slow remote history scan must
        // not hold the healthy provider behind a global bootstrap await.
        bootstrapComplete = true
        requestRecovery(.google); requestRecovery(.telegram)
        await refreshStoredSettings()
        scheduleAutomaticBackground()
        needsFreshScan = true
        schedulePolicyUpdate(); scheduleThrottledRefresh(); scheduleAutomaticBackup()
        consumeTransferWake()
        requestDrain()
        await trace(.startup, googleSession == nil || tdlibClient == nil ? .failed : .succeeded, id: id, started: started,
            failure: googleSession == nil || tdlibClient == nil ?
                SafeFailure(.invariant, domain: .core, cause: .setupUnavailable) : nil)
    }
    func startSubscriptions() {
        if let googleBackground {
            observers.append(Task { [weak self] in
                for await _ in googleBackground.events {
                    self?.scheduleThrottledRefresh()
                    if self?.isForeground == true { self?.requestRecovery(.google, force: true) }
                    else { self?.backgroundTransferWake() }
                }
            })
            observers.append(Task { [weak self] in
                for await _ in googleBackground.progressEvents { self?.scheduleThrottledRefresh() }
            })
        }
        if let ledger {
            observers.append(Task { [weak self] in
                do { for await _ in try await ledger.observeChanges() { self?.scheduleThrottledRefresh() } }
                catch { await self?.report(error, provider: nil) }
            })
        }
        let fallbackEvents = fallback.events
        observers.append(Task { [weak self] in
            for await _ in fallbackEvents { self?.scheduleThrottledRefresh() }
        })
        let paths = networkMonitor.events
        observers.append(Task { [weak self] in
            for await value in paths {
                guard self?.network != value else { continue }
                self?.network = value; self?.schedulePolicyUpdate()
                await self?.trace(.networkPolicy, .changed)
                if self?.connectionNetworkFailure == nil {
                    self?.requestRecovery(.google); self?.requestRecovery(.telegram)
                }
            }
        })
    }
    func startTelegramSubscriptions() {
        guard let client = tdlibClient, let adapter = telegramAdapter else { return }
        telegramObservers.append(Task { [weak self] in
            do {
                for try await update in try await client.updates(types: ["updateAuthorizationState", "updateConnectionState"]) {
                    if update.type == "updateAuthorizationState" {
                        let auth = await client.authorizationState
                        self?.updateTelegramAuthStep(auth)
                        if auth == .ready { self?.requestRecovery(.telegram) }
                    } else if update.type == "updateConnectionState",
                              update.object(forKey: "state")?.type == "connectionStateReady" {
                        self?.requestRecovery(.telegram)
                    }
                }
            } catch { await self?.report(error, provider: .telegram) }
        })
        let statuses = adapter.statusEvents, recovery = adapter.recoveryEvents
        telegramObservers.append(Task { [weak self] in
            for await _ in statuses { self?.scheduleThrottledRefresh() }
        })
        telegramObservers.append(Task { [weak self] in
            for await _ in recovery { self?.requestRecovery(.telegram) }
        })
    }
    public func scheduleThrottledRefresh() {
        scheduleProviderEnableChanges()
        guard isForeground || continuation.state == .running else { return }
        pendingRefresh = true
        guard refreshTask == nil, !shuttingDown else { return }
        refreshTask = Task { [weak self] in
            while self?.pendingRefresh == true && !Task.isCancelled {
                self?.pendingRefresh = false
                await self?.performUIRefresh()
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
            }
            self?.refreshTask = nil
        }
    }
    func report(_ error: any Error, provider: Provider?) async {
        let safe = ProviderSupport.safe(error, domain: provider == .google ? .google : (provider == .telegram ? .tdlib : .core))
        if let provider {
            providerErrors[provider] = safe
            if provider == .google { settingsState.googleAuthErrorMessage = explain(safe) }
            else { settingsState.telegramAuthErrorMessage = explain(safe) }
        } else { systemError = safe; dashboardState.waitingOrErrorReason = explain(safe) }
        do {
            let detail = ProviderSupport.coreCase(error).map {
                DiagnosticDetail(stage: .applicationOperation, status: .failed, correlationID: UUID(), coreError: $0)
            }
            try await ledger?.appendEvent(.failure, context: EventContext(origin: provider?.origin ?? .system, diagnostic: detail),
                                         decision: .wait, severity: .error, failure: safe)
        } catch { fallback.record(ProviderSupport.safe(error, domain: .sqlite)) }
        if ledger == nil { fallback.record(safe) }
        scheduleThrottledRefresh()
    }
    func explain(_ failure: SafeFailure) -> String { FailureExplanation.message(failure) }
}
