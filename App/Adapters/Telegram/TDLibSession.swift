import Foundation
import CloudifiedCore

/// High-level authorization states surfaced by TDLib.
/// Aligned with pinned TDLib commit 42e6a5259551178d1dab54a22ad96d14bd906e20.
public enum TDLibAuthorizationState: Sendable, Equatable {
    case uninitialized
    case waitTdlibParameters
    case waitPhoneNumber
    case waitPremiumPurchase
    case waitEmailAddress
    case waitEmailCode
    case waitCode
    case waitOtherDeviceConfirmation
    case waitRegistration
    case waitPassword
    case ready
    case loggingOut
    case closing
    case closed
    case uncertain
}

/// Parameters required to initialize a TDLib native database and network session.
/// Strictly matches td_api.tl `setTdlibParameters` schema at pinned commit.
public struct TDLibParameters: Sendable {
    public let apiId: Int32
    public let apiHash: String
    public let databaseDirectory: String
    public let filesDirectory: String
    public let databaseEncryptionKey: String
    public let useFileDatabase: Bool
    public let useChatInfoDatabase: Bool
    public let useMessageDatabase: Bool
    public let useSecretChats: Bool
    public let applicationVersion: String
    public let deviceModel: String
    public let systemVersion: String
    public let systemLanguageCode: String
    public let useTestDC: Bool

    public init(
        apiId: Int32,
        apiHash: String,
        databaseDirectory: String,
        filesDirectory: String,
        databaseEncryptionKey: String,
        useFileDatabase: Bool = true,
        useChatInfoDatabase: Bool = true,
        useMessageDatabase: Bool = true,
        useSecretChats: Bool = false,
        applicationVersion: String = "1.0.0",
        deviceModel: String = "iPhone",
        systemVersion: String = "iOS 26",
        systemLanguageCode: String = "en",
        useTestDC: Bool = false
    ) {
        self.apiId = apiId
        self.apiHash = apiHash
        self.databaseDirectory = databaseDirectory
        self.filesDirectory = filesDirectory
        self.databaseEncryptionKey = databaseEncryptionKey
        self.useFileDatabase = useFileDatabase
        self.useChatInfoDatabase = useChatInfoDatabase
        self.useMessageDatabase = useMessageDatabase
        self.useSecretChats = useSecretChats
        self.applicationVersion = applicationVersion
        self.deviceModel = deviceModel
        self.systemVersion = systemVersion
        self.systemLanguageCode = systemLanguageCode
        self.useTestDC = useTestDC
    }

    /// Converts to exact TDLib JSON request dictionary.
    public func toRequestDictionary() -> [String: Any] {
        [
            "@type": "setTdlibParameters",
            "use_test_dc": useTestDC,
            "database_directory": databaseDirectory,
            "files_directory": filesDirectory,
            "database_encryption_key": databaseEncryptionKey,
            "use_file_database": useFileDatabase,
            "use_chat_info_database": useChatInfoDatabase,
            "use_message_database": useMessageDatabase,
            "use_secret_chats": useSecretChats,
            "api_id": apiId,
            "api_hash": apiHash,
            "system_language_code": systemLanguageCode,
            "device_model": deviceModel,
            "system_version": systemVersion,
            "application_version": applicationVersion
        ]
    }
}

/// Actor owning a single active TDLib client session.
/// Routes requests/updates through the process-global TDLibProcessReceiver,
/// enforces bounded memory and request maps, handles deadlines without hangs,
/// coalesces file progress and fences critical delivery overflow,
/// and manages deterministic native close acknowledgement.
public actor TDLibSession {
    public static let maxPendingRequests = 16
    public static let maxSubscribers = 2
    public static let maxBufferedUpdates = 16
    public static let maxTrackedFiles = 32

    private struct PendingRequest {
        let continuation: CheckedContinuation<TDLibResponse, any Error>
        let timeoutTask: Task<Void, Never>
        let method: DiagnosticNativeMethod
        let started: TimeInterval
    }

    private let bridge: TDLibBridge
    private let receiver: TDLibProcessReceiver
    private let diagnosticSink: (@Sendable (EventOperation, EventContext, EventDecision, EventSeverity, SafeFailure?, TimeInterval?, Int64?, Int64?) async throws -> Void)?

    private var clientID: Int32?
    private var pendingRequests: [String: PendingRequest] = [:]
    private var updateContinuations: [UUID: AsyncThrowingStream<TDLibResponse, any Error>.Continuation] = [:]
    private var updateFilters: [UUID: Set<String>] = [:]
    private var updatePredicates: [UUID: @Sendable (TDLibResponse) -> Bool] = [:]
    private var processingFailure: (any Error)?

    private var currentAuthState: TDLibAuthorizationState = .uninitialized
    private var isStarting = false
    private var isClosing = false
    private var isTerminated = false
    private var closeTask: Task<Void, any Error>?

    private struct FileTransferFlags: Sendable, Equatable {
        let uploading: Bool
        let uploaded: Bool
        let downloading: Bool
        let downloaded: Bool
        var active: Bool { uploading || downloading }
    }
    private struct FileTransferTracking: Sendable {
        var flags: FileTransferFlags
        var lastEmittedUptime: TimeInterval
        var latest: TDLibResponse?
    }
    private var fileTransferTracking: [Int64: FileTransferTracking] = [:]
    private var progressFlushTask: Task<Void, Never>?

    public init(
        bridge: TDLibBridge = TDLibBridge(),
        receiver: TDLibProcessReceiver = .shared,
        diagnosticSink: (@Sendable (EventOperation, EventContext, EventDecision, EventSeverity, SafeFailure?, TimeInterval?, Int64?, Int64?) async throws -> Void)? = nil
    ) {
        self.bridge = bridge
        self.receiver = receiver
        self.diagnosticSink = diagnosticSink
    }

    /// Current authorization state.
    public var authState: TDLibAuthorizationState {
        currentAuthState
    }

    /// Whether this session has been terminated.
    public var isClosed: Bool {
        isTerminated
    }
    var hasNativeClient: Bool { clientID != nil }
    /// A delivery/log gap fences new commands; it is not remote rejection/absence.
    public var requiresReconciliation: Bool { processingFailure != nil }
    var inputFailure: SafeFailure? { processingFailure.map { TDLibClient.classify($0) } }
    var restartableProtocolFailure: Bool {
        guard let error = processingFailure as? TDLibError else { return false }
        switch error {
        case .malformedResponse, .responseLimitExceeded, .capacityExceeded: return true
        default: return false
        }
    }

    /// A protocol gap cannot be cleared in place: native readers may still exist.
    /// Close, join the receiver, then let the adapter rebuild from durable holds.
    func closeForProtocolRecovery() async throws {
        guard restartableProtocolFailure else { throw CoreError.recoveryRequired }
        do { try await close() }
        catch {
            try Task.checkCancellation()
            guard isTerminated, clientID == nil,
                  let original = processingFailure as? TDLibError,
                  (error as? TDLibError) == original else { throw error }
        }
    }
    public private(set) var connectionReady = false

    // MARK: - Lifecycle

    /// Initializes and starts the owned TDLib client and registers with the process receiver.
    public func start() async throws -> Int32 {
        guard clientID == nil, closeTask == nil, !isStarting else {
            throw TDLibError.executionFailed("TDLibSession is already started.")
        }
        isStarting = true
        defer { isStarting = false }
        self.isTerminated = false
        self.isClosing = false
        self.currentAuthState = .uninitialized
        self.processingFailure = nil

        // Atomically create native client ID and register session handler with receiver
        let id = try await receiver.createAndRegisterSession { [self] result in
            await handleIncomingResponse(result)
        }
        self.clientID = id

        try await emitDiagnostic(.appStart, decision: .proceed, severity: .info)
        return id
    }

    /// Subscribes to the broadcast stream of TDLib updates with bounded buffer policy.
    public func updateStream(types: Set<String>? = nil, accepting: (@Sendable (TDLibResponse) -> Bool)? = nil) throws -> AsyncThrowingStream<TDLibResponse, any Error> {
        if let processingFailure { throw processingFailure }
        guard !isTerminated else { throw TDLibError.clientClosed }
        guard updateContinuations.count < Self.maxSubscribers else {
            throw TDLibError.capacityExceeded("Maximum subscriber limit reached (\(Self.maxSubscribers)).")
        }

        let streamID = UUID()
        return AsyncThrowingStream(bufferingPolicy: .bufferingOldest(Self.maxBufferedUpdates)) { continuation in
            self.registerUpdateContinuation(continuation, id: streamID)
            self.updateFilters[streamID] = types
            self.updatePredicates[streamID] = accepting
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.unregisterUpdateContinuation(id: streamID)
                }
            }
        }
    }

    private func registerUpdateContinuation(_ continuation: AsyncThrowingStream<TDLibResponse, any Error>.Continuation, id: UUID) {
        updateContinuations[id] = continuation
    }

    private func unregisterUpdateContinuation(id: UUID) {
        updateContinuations.removeValue(forKey: id)
        updateFilters.removeValue(forKey: id)
        updatePredicates.removeValue(forKey: id)
    }

    // MARK: - Request Dispatch & Correlation

    /// Sends an asynchronous TDLib request and waits for the correlated response.
    /// Strictly validates finite positive timeouts, registers atomically, and uses
    /// a single terminal resolver to guarantee continuation resolution without hangs.
    public func sendRequest(_ request: [String: Any], timeout: TimeInterval = 60.0,
                            onDispatched: (@Sendable () -> Void)? = nil) async throws -> TDLibResponse {
        try Task.checkCancellation()
        if let processingFailure { throw processingFailure }
        guard timeout.isFinite, timeout > 0, timeout <= 300.0 else {
            throw TDLibError.invalidParameter("Timeout must be finite positive number <= 300 seconds.")
        }
        guard let clientID, !isStarting, !isTerminated, !isClosing else {
            throw TDLibError.clientClosed
        }
        guard pendingRequests.count < Self.maxPendingRequests else {
            throw TDLibError.capacityExceeded("Pending requests limit reached (\(Self.maxPendingRequests)).")
        }

        var mutableReq = request
        let extraID = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        let method = DiagnosticNativeMethod(rawValue: request["@type"] as? String ?? "") ?? .other
        try await diagnosticSink?(.nativeRequest, EventContext(origin: .telegram,
            diagnostic: DiagnosticDetail(stage: .nativeRequest, status: .started,
                correlationID: UUID(uuidString: extraID)!, nativeMethod: method)),
            .proceed, .info, nil, nil, nil, nil)
        // The sink is an actor suspension point; validate native ownership again.
        try Task.checkCancellation()
        if let processingFailure { throw processingFailure }
        guard self.clientID == clientID, !isStarting, !isTerminated, !isClosing else { throw TDLibError.clientClosed }
        guard pendingRequests.count < Self.maxPendingRequests else { throw TDLibError.capacityExceeded("Pending request capacity.") }
        mutableReq["@extra"] = extraID

        let jsonString = try TDLibJSON.serializeRequest(mutableReq)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                // Spawn dedicated deadline timer
                let timeoutTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                    catch { return }
                    await self?.resolveFailure(id: extraID, error: TDLibError.timeout)
                }

                self.pendingRequests[extraID] = PendingRequest(
                    continuation: continuation,
                    timeoutTask: timeoutTask,
                    method: method, started: started
                )

                // Dispatch to C ABI
                self.bridge.send(clientID: clientID, jsonRequest: jsonString)
                onDispatched?()
            }
        } onCancel: {
            Task { [weak self] in
                await self?.resolveFailure(id: extraID, error: CancellationError())
            }
        }
    }

    private func resolvePendingRequest(id: String, result: Result<TDLibResponse, any Error>) {
        guard let pending = pendingRequests.removeValue(forKey: id) else {
            return
        }
        pending.timeoutTask.cancel()

        pending.continuation.resume(with: result)
    }

    private func resolveFailure(id: String, error: any Error) async {
        // Reserve the terminal result before awaiting a potentially slow sink.
        guard let pending = pendingRequests.removeValue(forKey: id) else { return }
        // The deadline task must not cancel itself before persisting its event.
        if (error as? TDLibError) != .timeout { pending.timeoutTask.cancel() }
        do {
            try await requestTrace(id: id, pending: pending, status: .failed, failure: TDLibClient.classify(error, method: pending.method),
                                   reason: TDLibClient.nativeReason(error))
            pending.continuation.resume(throwing: error)
        } catch {
            pending.continuation.resume(throwing: error)
            interruptInput(error)
        }
    }

    private func requestTrace(id: String, pending: PendingRequest, status: DiagnosticStatus,
                              failure: SafeFailure? = nil, reason: DiagnosticNativeError? = nil) async throws {
        try await diagnosticSink?(.nativeRequest, EventContext(origin: .telegram,
            diagnostic: DiagnosticDetail(stage: .nativeRequest, status: status,
                correlationID: UUID(uuidString: id) ?? UUID(), nativeMethod: pending.method, nativeError: reason)),
            failure == nil ? .proceed : .wait, failure == nil ? .info : .error, failure,
            max(0, ProcessInfo.processInfo.systemUptime - pending.started), nil, nil)
    }

    private func interruptInput(_ error: any Error) {
        if processingFailure == nil, case TDLibError.capacityExceeded = error {
            let sink = diagnosticSink, failure = TDLibClient.classify(error)
            let context = EventContext(origin: .telegram, diagnostic: DiagnosticDetail(stage: .telegramProtocol,
                status: .failed, correlationID: UUID(), nativeError: TDLibClient.nativeReason(error)))
            Task { try? await sink?(.setupTrace, context, .reconcile, .error, failure, nil, nil, nil) }
        }
        if processingFailure == nil { processingFailure = error }
        let failure = processingFailure!
        for id in Array(pendingRequests.keys) {
            resolvePendingRequest(id: id, result: .failure(failure))
        }
        progressFlushTask?.cancel()
        progressFlushTask = nil
        fileTransferTracking.removeAll()
        for continuation in updateContinuations.values { continuation.finish(throwing: failure) }
        updateContinuations.removeAll()
        updateFilters.removeAll()
        updatePredicates.removeAll()
        // Keep the receiver/native client alive for real close acknowledgement.
    }

    // MARK: - Incoming Message Handling

    private func handleIncomingResponse(_ result: Result<TDLibResponse, TDLibError>) async {
        let response: TDLibResponse
        do { response = try result.get() }
        catch {
            let first = processingFailure == nil
            let requests = Array(pendingRequests)
            interruptInput(error)
            if first {
                let failure = TDLibClient.classify(error)
                for (id, pending) in requests {
                    try? await requestTrace(id: id, pending: pending, status: .failed,
                        failure: failure, reason: TDLibClient.nativeReason(error))
                }
                try? await diagnosticSink?(.setupTrace, EventContext(origin: .telegram,
                    diagnostic: DiagnosticDetail(stage: .telegramProtocol, status: .failed,
                        correlationID: UUID(), nativeError: TDLibClient.nativeReason(error))),
                    .reconcile, .error, failure, nil, nil, nil)
            }
            return
        }

        // Correlate with pending request via @extra if present
        if let extra = response.extra, pendingRequests[extra] != nil {
            if response.isError {
                let code = response.errorCode ?? 0
                let message = response.errorMessage ?? "TDLib error"
                await resolveFailure(id: extra, error: TDLibError.tdlibError(code: code, message: message))
            } else {
                // Bootstrap query is a real first request: TDLib emits no updates
                // before that request. Apply its auth snapshot before resuming.
                if let type = response.type, type.hasPrefix("authorizationState") {
                    let closed = await handleAuthStateUpdate(type)
                    if closed { await completeClosure() }
                }
                if let pending = pendingRequests.removeValue(forKey: extra) {
                    pending.timeoutTask.cancel()
                    do {
                        try await requestTrace(id: extra, pending: pending, status: .succeeded)
                        pending.continuation.resume(returning: response)
                    } catch {
                        pending.continuation.resume(throwing: error); interruptInput(error)
                    }
                }
            }
            return
        }

        var isClosedAcknowledgement = false
        // Process authorization state updates
        if let type = response.type {
            if type == "updateAuthorizationState" {
                if let stateObj = response.object(forKey: "authorization_state"),
                   let stateType = stateObj.type {
                    isClosedAcknowledgement = await handleAuthStateUpdate(stateType)
                }
            } else if type == "updateConnectionState" {
                guard let state = response.object(forKey: "state")?.type,
                      ["connectionStateWaitingForNetwork", "connectionStateConnectingToProxy", "connectionStateConnecting", "connectionStateUpdating", "connectionStateReady"].contains(state) else {
                    connectionReady = false; interruptInput(TDLibError.malformedResponse); return
                }
                connectionReady = state == "connectionStateReady"
            } else if type == "updateFile" {
                if !processFileProgress(response) { return }
            }
        }

        // Even if publishing overflows, a genuine native close still releases
        // native ownership. A delivery failure remains a separate sticky fact.
        publish(response)
        if isClosedAcknowledgement { await completeClosure() }
    }

    private func publish(_ response: TDLibResponse) {
        guard processingFailure == nil else { return }
        for (id, continuation) in Array(updateContinuations) {
            // Filter before enqueue, never by dropping from a full critical buffer.
            if let types = updateFilters[id], let type = response.type, !types.contains(type) { continue }
            if let accepting = updatePredicates[id], !accepting(response) { continue }
            switch continuation.yield(response) {
            case .enqueued: break
            case .terminated: unregisterUpdateContinuation(id: id)
            case .dropped:
                interruptInput(TDLibError.capacityExceeded("Critical update overflow."))
                return
            @unknown default:
                interruptInput(TDLibError.malformedResponse)
                return
            }
        }
    }

    /// Retain only the latest intermediate sample, flush even if callbacks stop.
    /// Every active/inactive/completed transition passes immediately.
    private func processFileProgress(_ response: TDLibResponse) -> Bool {
        guard processingFailure == nil else { return false }
        guard let file = response.object(forKey: "file"), let id = file.int64(forKey: "id"),
              let remote = file.object(forKey: "remote"), let local = file.object(forKey: "local"),
              let uploading = remote.bool(forKey: "is_uploading_active"),
              let uploaded = remote.bool(forKey: "is_uploading_completed"),
              let downloading = local.bool(forKey: "is_downloading_active"),
              let downloaded = local.bool(forKey: "is_downloading_completed") else {
            interruptInput(TDLibError.malformedResponse)
            return false
        }
        let flags = FileTransferFlags(uploading: uploading, uploaded: uploaded,
                                      downloading: downloading, downloaded: downloaded)
        let now = ProcessInfo.processInfo.systemUptime
        let old = fileTransferTracking[id]
        let immediate = old == nil || old?.flags != flags || now - (old?.lastEmittedUptime ?? 0) >= 0.5
        guard flags.active else {
            fileTransferTracking.removeValue(forKey: id)
            return true
        }
        guard old != nil || fileTransferTracking.count < Self.maxTrackedFiles else {
            interruptInput(TDLibError.capacityExceeded("File progress capacity exceeded."))
            return false
        }
        fileTransferTracking[id] = FileTransferTracking(
            flags: flags, lastEmittedUptime: immediate ? now : old!.lastEmittedUptime,
            latest: immediate ? nil : response)
        if !immediate { startProgressFlushIfNeeded() }
        return immediate
    }

    private func startProgressFlushIfNeeded() {
        guard progressFlushTask == nil else { return }
        progressFlushTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 500_000_000) }
                catch { return }
                guard let self, await self.flushProgress() else { return }
            }
        }
    }

    private func flushProgress() -> Bool {
        for (id, record) in Array(fileTransferTracking) {
            guard let latest = record.latest else { continue }
            fileTransferTracking[id]?.latest = nil
            fileTransferTracking[id]?.lastEmittedUptime = ProcessInfo.processInfo.systemUptime
            publish(latest)
            if processingFailure != nil { return false }
        }
        // All latest values were flushed; a later sample starts a fresh timer.
        progressFlushTask = nil
        return false
    }

    private func handleAuthStateUpdate(_ stateType: String) async -> Bool {
        let oldState = currentAuthState
        var isClosed = false
        switch stateType {
        case "authorizationStateWaitTdlibParameters":
            currentAuthState = .waitTdlibParameters
        case "authorizationStateWaitPhoneNumber":
            currentAuthState = .waitPhoneNumber
        case "authorizationStateWaitPremiumPurchase":
            currentAuthState = .waitPremiumPurchase
        case "authorizationStateWaitEmailAddress":
            currentAuthState = .waitEmailAddress
        case "authorizationStateWaitEmailCode":
            currentAuthState = .waitEmailCode
        case "authorizationStateWaitCode":
            currentAuthState = .waitCode
        case "authorizationStateWaitOtherDeviceConfirmation":
            currentAuthState = .waitOtherDeviceConfirmation
        case "authorizationStateWaitRegistration":
            currentAuthState = .waitRegistration
        case "authorizationStateWaitPassword":
            currentAuthState = .waitPassword
        case "authorizationStateReady":
            currentAuthState = .ready
        case "authorizationStateLoggingOut":
            currentAuthState = .loggingOut
        case "authorizationStateClosing":
            currentAuthState = .closing
        case "authorizationStateClosed":
            currentAuthState = .closed
            isClosed = true
        default:
            currentAuthState = .uncertain
            interruptInput(TDLibError.malformedResponse)
        }

        if oldState != currentAuthState {
            do {
                try await diagnosticSink?(.setupTrace, EventContext(origin: .telegram,
                    diagnostic: DiagnosticDetail(stage: .telegramAuthState, status: .changed,
                        correlationID: UUID(), authState: DiagnosticAuthState(rawValue: String(describing: currentAuthState)))),
                    .proceed, .info, nil, nil, nil, nil)
            }
            catch { interruptInput(error) }
        }
        return isClosed
    }

    // MARK: - Close Handling

    /// Closes the client session and awaits terminal closed acknowledgement from native TDLib.
    /// All concurrent close callers await the same closure Task.
    public func close() async throws {
        guard !isStarting else { throw TDLibError.unresolvedClose("Session creation is still in progress.") }
        if let existing = closeTask {
            return try await existing.value
        }

        let task = Task { [self] in
            try await performClose()
        }
        self.closeTask = task
        defer { self.closeTask = nil }
        return try await task.value
    }

    private func performClose() async throws {
        if let clientID, !isTerminated {
            self.isClosing = true
            self.currentAuthState = .closing
            let closeJSON = try TDLibJSON.serializeRequest(["@type": "close"])
            bridge.send(clientID: clientID, jsonRequest: closeJSON)
        } else if clientID == nil, !isTerminated {
            return // Never started: no native owner to retire.
        }

        // Await native confirmation with finite bounded deadline (10 seconds)
        let maxWaitSeconds: TimeInterval = 10.0
        let start = ProcessInfo.processInfo.systemUptime
        while (!isTerminated || self.clientID != nil) && (ProcessInfo.processInfo.systemUptime - start) < maxWaitSeconds {
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { throw TDLibError.unresolvedClose("Close interrupted; native confirmation remains pending.") }
        }

        if !isTerminated || self.clientID != nil {
            // Unresolved close deadline: do NOT fabricate closed state
            if !isTerminated { currentAuthState = .uncertain }
            try await emitDiagnostic(
                .failure,
                decision: .wait,
                severity: .error,
                failure: SafeFailure(.invariant, domain: .tdlib, cause: .interrupted)
            )
            throw TDLibError.unresolvedClose("TDLib did not acknowledge authorizationStateClosed within \(maxWaitSeconds)s.")
        }
        await receiver.joinIdle()
        if let processingFailure { throw processingFailure }
    }

    private func completeClosure() async {
        guard !isTerminated else { return }
        isTerminated = true
        isClosing = false
        currentAuthState = .closed

        // Cancel and resolve all pending requests
        for id in Array(pendingRequests.keys) {
            resolvePendingRequest(id: id, result: .failure(TDLibError.clientClosed))
        }
        pendingRequests.removeAll()

        progressFlushTask?.cancel()
        progressFlushTask = nil
        fileTransferTracking.removeAll()

        // Persist before completing streams; error remains sticky even though
        // native closure is factual. Never await the receive-task join here.
        do { try await emitDiagnostic(.finalization, decision: .proceed, severity: .info) }
        catch { interruptInput(error) }
        if let cid = clientID { await receiver.unregisterSession(clientID: cid) }
        clientID = nil

        for continuation in updateContinuations.values {
            if let processingFailure { continuation.finish(throwing: processingFailure) }
            else { continuation.finish() }
        }
        updateContinuations.removeAll()
        updateFilters.removeAll()
        updatePredicates.removeAll()
    }

    private func emitDiagnostic(
        _ operation: EventOperation,
        decision: EventDecision,
        severity: EventSeverity,
        failure: SafeFailure? = nil,
        duration: TimeInterval? = nil,
        bytes: Int64? = nil,
        expectedBytes: Int64? = nil
    ) async throws {
        guard let diagnosticSink else { return }
        let context = EventContext(origin: .telegram)
        do { try await diagnosticSink(operation, context, decision, severity, failure, duration, bytes, expectedBytes) }
        catch { interruptInput(error); throw error }
    }
}
