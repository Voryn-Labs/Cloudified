import Foundation
import CTDLib

/// Classified errors from the native TDLib C bridge.
public enum TDLibResponseLimit: String, Sendable { case bytes, nodes, depth }

public enum TDLibError: LocalizedError, Sendable, Equatable {
    case nativeLibraryMissing(String)
    case clientCreationFailed
    case clientClosed
    case unresolvedClose(String)
    case timeout
    case capacityExceeded(String)
    case executionFailed(String)
    case malformedResponse
    case responseLimitExceeded(TDLibResponseLimit)
    case invalidParameter(String)
    case tdlibError(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .nativeLibraryMissing:
            return "Native TDLib library is unavailable."
        case .clientCreationFailed:
            return "Failed to create TDLib client instance."
        case .clientClosed:
            return "TDLib client session has been closed."
        case .unresolvedClose:
            return "TDLib has not confirmed closure; resource ownership remains unresolved."
        case .timeout:
            return "TDLib request timed out."
        case .capacityExceeded:
            return "TDLib delivery capacity exceeded; reconciliation is required."
        case .executionFailed:
            return "TDLib could not complete the operation."
        case .malformedResponse:
            return "TDLib returned a response Cloudified could not decode."
        case .responseLimitExceeded:
            return "TDLib response exceeded Cloudified's bounded decoder capacity."
        case .invalidParameter:
            return "Invalid TDLib request parameters."
        case .tdlibError(let code, _):
            return "TDLib rejected the request (code \(code))."
        }
    }
}

/// Narrow, low-level Swift bridge to TDLib's C JSON interface.
/// Strictly honors the C pointer ownership and lifetime rules defined in `td_json_client.h`:
/// pointers returned by `td_receive` / `td_execute` are copied immediately into Swift
/// memory before the next call on that thread.
public final class TDLibBridge: Sendable {
    // Returned native pointers stay protected through the copy, including execute.
    private static let pointerLock = NSLock()
    public init() {}

    /// Creates an opaque TDLib client identifier.
    /// Fails fast with `TDLibError.clientCreationFailed` if client ID creation fails.
    public func createClientID() throws -> Int32 {
        let clientID = td_create_client_id()
        guard clientID > 0 else {
            throw TDLibError.clientCreationFailed
        }
        return clientID
    }

    /// Sends a JSON request string to TDLib for the given client.
    public func send(clientID: Int32, jsonRequest: String) {
        jsonRequest.withCString { cStr in
            td_send(clientID, cStr)
        }
    }

    /// Receives the next response or update from TDLib with the specified timeout.
    /// Must only be called from a single process-global thread/task.
    /// The returned UTF-8 string is copied immediately from TDLib's memory.
    fileprivate func receive(timeout: Double) throws -> String? {
        Self.pointerLock.lock(); defer { Self.pointerLock.unlock() }
        guard let cStr = td_receive(timeout) else {
            return nil
        }
        return try Self.copyResponse(cStr)
    }

    /// Synchronously executes a service TDLib request.
    /// The returned UTF-8 string is copied immediately from TDLib's memory.
    public func execute(jsonRequest: String) throws -> String? {
        Self.pointerLock.lock(); defer { Self.pointerLock.unlock() }
        return try jsonRequest.withCString { cStr in
            guard let cStrRes = td_execute(cStr) else {
                return nil
            }
            return try Self.copyResponse(cStrRes)
        }
    }

    /// Bound the native read before allocating a Swift string; invalid UTF-8 fails.
    private static func copyResponse(_ pointer: UnsafePointer<CChar>) throws -> String {
        let length = strnlen(pointer, TDLibJSON.maxJSONBytes + 1)
        guard length <= TDLibJSON.maxJSONBytes else { throw TDLibError.responseLimitExceeded(.bytes) }
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        guard let string = String(bytes: UnsafeBufferPointer(start: bytes, count: length), encoding: .utf8) else {
            throw TDLibError.malformedResponse
        }
        return string
    }

    /// Sets the native log message callback and verbosity level.
    public func setLogMessageCallback(maxVerbosity: Int32, callback: td_log_message_callback_ptr?) {
        td_set_log_message_callback(maxVerbosity, callback)
    }
}

/// Process-wide receiver router that guarantees exactly one Task calls `td_receive`,
/// routing updates by `@client_id` to registered session actors without busy-spinning.
public actor TDLibProcessReceiver {
    public static let shared = TDLibProcessReceiver()
    // One mapped Telegram account executes at a time; Google is independent.
    public static let maxActiveSessions = 1

    private let bridge = TDLibBridge()
    private var activeSessions: [Int32: @Sendable (Result<TDLibResponse, TDLibError>) async -> Void] = [:]
    private var receiveTask: Task<Void, Never>?
    private var receiveGeneration: UUID?
    private var draining = false

    private init() {}

    /// Recheck reservations after every suspension. Never create an unowned native ID.
    public func createAndRegisterSession(
        handler: @escaping @Sendable (Result<TDLibResponse, TDLibError>) async -> Void
    ) async throws -> Int32 {
        while draining, let oldTask = receiveTask, let generation = receiveGeneration {
            await oldTask.value
            releaseJoinedTask(generation: generation)
        }
        try Task.checkCancellation()
        guard activeSessions.count < Self.maxActiveSessions else {
            throw TDLibError.capacityExceeded("A Telegram session still owns the native client.")
        }
        let id = try bridge.createClientID()
        activeSessions[id] = handler
        startReceiveLoopIfNeeded()
        return id
    }

    // Called only after a genuine native closed acknowledgement. Do not join from
    // its handler: the receive task is awaiting that handler and must first return.
    func unregisterSession(clientID: Int32) {
        activeSessions.removeValue(forKey: clientID)
        if activeSessions.isEmpty { draining = true }
    }

    public func hasActiveSessions() -> Bool { !activeSessions.isEmpty }

    /// Close callers join outside receive callbacks; retain the task until it exits.
    public func joinIdle() async {
        guard activeSessions.isEmpty, let task = receiveTask, let generation = receiveGeneration else { return }
        await task.value
        releaseJoinedTask(generation: generation)
    }

    private func shouldReceive() -> Bool { !draining && !activeSessions.isEmpty }

    private func startReceiveLoopIfNeeded() {
        guard receiveTask == nil else { return }
        draining = false
        receiveGeneration = UUID()
        receiveTask = Task.detached(priority: .userInitiated) { [self, bridge] in
            while await shouldReceive() {
                do {
                    if let json = try bridge.receive(timeout: 0.25) {
                        await routeIncomingJSON(json)
                    }
                } catch { await reportProtocolFailure(error as? TDLibError ?? .malformedResponse) }
            }
            // Leave the completed task retained until an external caller joins it.
        }
    }

    private func releaseJoinedTask(generation: UUID) {
        // Multiple joiners may resume after a replacement is registered.
        guard receiveGeneration == generation else { return }
        receiveTask = nil
        receiveGeneration = nil
        draining = false
    }

    private func routeIncomingJSON(_ json: String) async {
        let response: TDLibResponse
        do { response = try TDLibJSON.parse(json) }
        catch { await reportProtocolFailure(error as? TDLibError ?? .malformedResponse); return }
        guard let id = response.clientID, id > 0 else {
            await reportProtocolFailure()
            return
        }
        guard let handler = activeSessions[id] else { return }
        await handler(.success(response))
    }

    private func reportProtocolFailure(_ error: TDLibError = .malformedResponse) async {
        for handler in Array(activeSessions.values) {
            await handler(.failure(error))
        }
    }
}
