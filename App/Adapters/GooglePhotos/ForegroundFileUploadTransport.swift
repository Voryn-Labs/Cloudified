import Foundation
import CloudifiedCore

/// One file reader per Google lane. Response bytes are bounded; cancellation
/// completes only through didCompleteWithError, after URLSession releases input.
final class ForegroundFileUploadTransport: NSObject, FileUploadTransport, URLSessionDataDelegate, @unchecked Sendable {
    let continuesAfterProcessExit = false
    private struct Operation {
        let id: UUID
        let task: URLSessionTask
        let continuation: CheckedContinuation<FileUploadResult, any Error>
        let progress: @Sendable (Int64, Int64) -> Void
        var data = Data()
        let responseLimit: Int
        var overflow = false
    }
    private let lock = NSLock()
    private var operations: [Int: Operation] = [:]
    private let configuration: URLSessionConfiguration
    private let reuseDataSession: Bool
    init(configuration: URLSessionConfiguration = .ephemeral, reuseDataSession: Bool = false) {
        self.configuration = configuration.copy() as! URLSessionConfiguration
        self.reuseDataSession = reuseDataSession
        super.init()
    }
    // Reused control requests keep their connection pool, but never retain the
    // transport through URLSession's strong delegate ownership.
    private final class WeakDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        weak var owner: ForegroundFileUploadTransport?
        init(_ owner: ForegroundFileUploadTransport) { self.owner = owner }
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            owner?.urlSession(session, dataTask: dataTask, didReceive: data)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            owner?.urlSession(session, task: task, didCompleteWithError: error)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    private var activeSession: URLSession?
    deinit { activeSession?.invalidateAndCancel() }

    func upload(_ request: URLRequest, fromFile file: URL, transferID: UUID,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> FileUploadResult {
        try await perform(request, file: file, transferID: transferID, progress: progress)
    }
    func requestData(_ request: URLRequest, responseLimit: Int = 1_048_576, onStart: @escaping @Sendable () -> Void = {}) async throws -> (Data, URLResponse) {
        let result = try await perform(request, file: nil, transferID: UUID(), progress: { _, _ in }, onStart: onStart, responseLimit: responseLimit)
        return (result.data, result.response)
    }
    private func perform(_ request: URLRequest, file: URL?, transferID: UUID,
                         progress: @escaping @Sendable (Int64, Int64) -> Void, onStart: @escaping @Sendable () -> Void = {}, responseLimit: Int = 1_048_576) async throws -> FileUploadResult {
        guard responseLimit == 1_048_576 || responseLimit == 4_194_304 else { throw CoreError.invalidContract }
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard operations.count < (reuseDataSession ? 4 : 1) else { lock.unlock(); continuation.resume(throwing: GPMCError(kind: .transport, message: "Upload already active.")); return }
                guard !reuseDataSession || file == nil else { lock.unlock(); continuation.resume(throwing: CoreError.invalidContract); return }
                let config = configuration.copy() as! URLSessionConfiguration
                config.waitsForConnectivity = file != nil; config.urlCache = nil
                config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
                config.timeoutIntervalForRequest = min(request.timeoutInterval, file == nil ? 45 : 120)
                config.timeoutIntervalForResource = file == nil ? 60 : 3600
                let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
                let owned: URLSession
                if reuseDataSession, let existing = activeSession { owned = existing }
                else { owned = URLSession(configuration: config, delegate: reuseDataSession ? WeakDelegate(self) : self, delegateQueue: queue) }
                // A reusable data session has stable config; per-request limits
                // still honor shorter callers' deadlines after its first task.
                var bounded = request
                if file == nil { bounded.timeoutInterval = min(request.timeoutInterval, 45) }
                let task: URLSessionTask = file.map { owned.uploadTask(with: bounded, fromFile: $0) } ?? owned.dataTask(with: bounded)
                operations[task.taskIdentifier] = Operation(id: transferID, task: task, continuation: continuation, progress: progress, responseLimit: responseLimit)
                activeSession = owned
                onStart()
                task.resume()
                if Task.isCancelled { task.cancel() }
                lock.unlock()
            }
        } onCancel: { self.cancelNow(transferID) }
    }
    private func cancelNow(_ id: UUID) {
        lock.lock(); let task = operations.values.first { $0.id == id }?.task; lock.unlock(); task?.cancel()
    }
    func cancel(transferID: UUID) async { cancelNow(transferID) }
    func forget(transferID: UUID) async {} // No terminal associations are retained.
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        lock.lock(); let current = operations[task.taskIdentifier]; let report = current?.task === task ? current?.progress : nil; lock.unlock()
        report?(totalBytesSent, max(totalBytesSent, totalBytesExpectedToSend))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard var operation = operations[dataTask.taskIdentifier], operation.task === dataTask else { lock.unlock(); return }
        if operation.data.count + data.count > operation.responseLimit { operation.overflow = true; dataTask.cancel() }
        else { operation.data.append(data) }
        operations[dataTask.taskIdentifier] = operation
        lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        lock.lock()
        guard let completed = operations[task.taskIdentifier], completed.task === task else { lock.unlock(); return }
        operations.removeValue(forKey: task.taskIdentifier)
        if !reuseDataSession { activeSession = nil }
        lock.unlock()
        if !reuseDataSession { session.finishTasksAndInvalidate() }
        if completed.overflow { completed.continuation.resume(throwing: GPMCError(kind: .malformed, message: "Control response exceeded limit.", googleReason: .responseLimit)) }
        else if let error {
            if (error as? URLError)?.code == .cancelled { completed.continuation.resume(throwing: CancellationError()) }
            else { completed.continuation.resume(throwing: GPMCError(kind: .transport, message: "Network transport failed.", transportFailure: ProviderSupport.safe(error, domain: .urlSession))) }
        } else if let response = task.response as? HTTPURLResponse {
            completed.continuation.resume(returning: FileUploadResult(data: completed.data, response: response))
        } else { completed.continuation.resume(throwing: GPMCError(kind: .malformed, message: "Upload response missing.")) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Resumable uploads have a pinned Google endpoint. Do not follow an
        // arbitrary redirect with private original bytes or credentials.
        completionHandler(nil)
    }
}
