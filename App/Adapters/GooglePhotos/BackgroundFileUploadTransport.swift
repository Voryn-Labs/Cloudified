import Foundation
import CloudifiedCore
import UIKit

/// File-only OS transport. Cancellation detaches a Swift waiter; it never declares
/// an OS reader dead. Result journals are small, protected and retained until the
/// provider has checkpointed a receipt/rejection. No credential/request logging.
final class BackgroundFileUploadTransport: NSObject, FileUploadTransport, URLSessionDataDelegate, @unchecked Sendable {
    enum Inventory: Sendable { case active(Int64, Int64), completed(FileUploadResult), failed(SafeFailure), absent }
    private struct Journal: Codable {
        let id: UUID
        var status: Int?
        var body: Data = Data()
        var failure: SafeFailure?
        var terminal = false
    }
    private struct Waiter {
        let continuation: CheckedContinuation<FileUploadResult, any Error>
        let progress: @Sendable (Int64, Int64) -> Void
    }
    let continuesAfterProcessExit: Bool
    let identifier: String
    let events: AsyncStream<Void>
    let progressEvents: AsyncStream<Void>
    private let eventSink: AsyncStream<Void>.Continuation
    private let progressSink: AsyncStream<Void>.Continuation
    private let root: URL
    private let lock = NSLock()
    private var waiters: [UUID: Waiter] = [:]
    private var tasks: [UUID: URLSessionTask] = [:]
    private var journals: [UUID: Journal] = [:]
    private var persistenceFailures: [UUID: SafeFailure] = [:]
    private var session: URLSession!
    private var closing = false
    private var lastProgressEvent: TimeInterval = 0

    init(root: URL) throws {
        self.root = root.appendingPathComponent("google-transfers", isDirectory: true)
        try StorageLayout.prepareDirectory(self.root, fileManager: .default)
        continuesAfterProcessExit = !AppRuntime.isHosted
        identifier = (Bundle.main.bundleIdentifier ?? "com.vorynlabs.cloudified") + ".original-upload"
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = stream.stream; eventSink = stream.continuation
        let progress = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        progressEvents = progress.stream; progressSink = progress.continuation
        super.init()
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let config: URLSessionConfiguration
        if continuesAfterProcessExit {
            config = .background(withIdentifier: identifier)
            config.sessionSendsLaunchEvents = true; config.isDiscretionary = false
        } else {
            config = .ephemeral
        }
        #else
        let config = URLSessionConfiguration.ephemeral
        #endif
        config.waitsForConnectivity = true; config.timeoutIntervalForResource = 7 * 24 * 3600
        config.timeoutIntervalForRequest = 120; config.httpMaximumConnectionsPerHost = 1
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }
    private func url(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
    private func write(_ journal: Journal) throws {
        try ProviderSupport.canonical(journal).write(to: url(journal.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func read(_ id: UUID) throws -> Journal? {
        if let journal = journals[id] { return journal }
        let path = url(id)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let attrs = try path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true, (attrs.fileSize ?? Int.max) <= 100_000 else { throw CoreError.invalidContract }
        let value = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: path))
        guard value.id == id, value.body.count <= 65_536 else { throw CoreError.invalidContract }
        journals[id] = value; return value
    }
    /// Must precede startup staging cleanup. getAllTasks is the OS reader inventory,
    /// not an assumption based on our in-memory dictionary or local journal alone.
    func activeTransferIDs() async throws -> Set<UUID> {
        let current = await session.allTasks
        return try lock.withLock {
            var result: Set<UUID> = []
            for task in current where task.state != .completed {
                guard let text = task.taskDescription, let id = UUID(uuidString: text) else { throw CoreError.recoveryRequired }
                tasks[id] = task; result.insert(id)
            }
            return result
        }
    }
    func inventory(_ id: UUID) async throws -> Inventory {
        let current = await session.allTasks
        return try lock.withLock {
            for task in current {
                guard let text = task.taskDescription, let key = UUID(uuidString: text), task.state != .completed else { continue }
                tasks[key] = task
            }
            if let failure = persistenceFailures[id] { throw failure }
            let journal = try read(id)
            if let task = tasks[id], current.contains(where: { $0 === task && $0.state != .completed }) || tasks[id] != nil && journal?.terminal != true {
                return .active(max(0, task.countOfBytesSent), max(0, task.countOfBytesExpectedToSend))
            }
            tasks.removeValue(forKey: id)
            guard let journal, journal.terminal else { return .absent }
            if let failure = journal.failure { return .failed(failure) }
            guard let status = journal.status, let response = HTTPURLResponse(url: URL(string: "https://photos.googleapis.com/")!, statusCode: status, httpVersion: nil, headerFields: nil) else { throw CoreError.invalidContract }
            return .completed(FileUploadResult(data: journal.body, response: response))
        }
    }
    func upload(_ request: URLRequest, fromFile file: URL, transferID: UUID,
                progress: @escaping @Sendable (Int64, Int64) -> Void) async throws -> FileUploadResult {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    do {
                        guard !closing else { throw CoreError.invalidTransition }
                        guard request.url?.scheme == "https", request.url?.host == "photos.googleapis.com", request.url?.user == nil, request.url?.password == nil else { throw CoreError.invalidContract }
                        if let failure = persistenceFailures.values.first { throw failure }
                        guard waiters[transferID] == nil, tasks[transferID] == nil, try read(transferID) == nil else { throw CoreError.recoveryRequired }
                        let journal = Journal(id: transferID)
                        try write(journal); journals[transferID] = journal
                        let task = session.uploadTask(with: request, fromFile: file)
                        task.taskDescription = transferID.uuidString
                        tasks[transferID] = task; waiters[transferID] = Waiter(continuation: continuation, progress: progress)
                        task.resume()
                    } catch { continuation.resume(throwing: error) }
                }
                if Task.isCancelled { detach(transferID) }
            }
        } onCancel: { self.detach(transferID) }
    }
    private func detach(_ id: UUID) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.continuation.resume(throwing: CancellationError())
    }
    /// Explicit transport cancellation is available, but terminal ownership still
    /// comes from didCompleteWithError/getAllTasks, never from task.cancel alone.
    func cancel(transferID: UUID) async { lock.withLock { tasks[transferID] }?.cancel() }
    func forget(transferID: UUID) async {
        lock.withLock {
            guard tasks[transferID] == nil, waiters[transferID] == nil else { return }
            do { if FileManager.default.fileExists(atPath: url(transferID).path) { try FileManager.default.removeItem(at: url(transferID)) }; journals.removeValue(forKey: transferID); persistenceFailures.removeValue(forKey: transferID) }
            catch { persistenceFailures[transferID] = ProviderSupport.safe(error, domain: .fileSystem) }
        }
    }
    /// Preserve live OS readers on shutdown, then break the session/delegate
    /// ownership when the last real callback has finished. No per-file sessions.
    func finishWhenIdle() async throws {
        _ = try await activeTransferIDs()
        let finish = lock.withLock { closing = true; return tasks.isEmpty }
        if finish { session.finishTasksAndInvalidate() }
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) { eventSink.finish(); progressSink.finish() }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let text = task.taskDescription, let id = UUID(uuidString: text) else { return }
        let report = lock.withLock { waiters[id]?.progress }
        report?(totalBytesSent, totalBytesExpectedToSend)
        let notify = lock.withLock {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastProgressEvent >= 0.5 else { return false }
            lastProgressEvent = now; return true
        }
        if notify { progressSink.yield(()) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let text = dataTask.taskDescription, let id = UUID(uuidString: text) else { dataTask.cancel(); return }
        lock.withLock {
            do {
                var journal = try read(id) ?? Journal(id: id)
                guard journal.body.count + data.count <= 65_536 else { throw CoreError.invalidContract }
                journal.body.append(data); try write(journal); journals[id] = journal
            } catch { persistenceFailures[id] = ProviderSupport.safe(error, domain: .fileSystem); dataTask.cancel() }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let text = task.taskDescription, let id = UUID(uuidString: text) else { return }
        let result: (Waiter?, Result<FileUploadResult, any Error>) = lock.withLock {
            tasks.removeValue(forKey: id)
            let waiter = waiters.removeValue(forKey: id)
            do {
                var journal = try read(id) ?? Journal(id: id)
                journal.terminal = true; journal.status = (task.response as? HTTPURLResponse)?.statusCode
                journal.failure = persistenceFailures[id] ?? error.map { ProviderSupport.safe($0, domain: .urlSession) }
                if journal.failure == nil && journal.status == nil { journal.failure = SafeFailure(.transfer, domain: .urlSession, cause: .outcomeUnknown) }
                try write(journal); journals[id] = journal
                if let failure = journal.failure { return (waiter, .failure(failure)) }
                guard let response = task.response as? HTTPURLResponse else { throw CoreError.invalidContract }
                return (waiter, .success(FileUploadResult(data: journal.body, response: response)))
            } catch { let safe = ProviderSupport.safe(error, domain: .fileSystem); persistenceFailures[id] = safe; return (waiter, .failure(safe)) }
        }
        result.0?.continuation.resume(with: result.1)
        // An attached lane owns checkpoint/commit and schedules recovery itself
        // if its outcome retains inputs. Forcing recovery here interrupts every
        // normal job boundary and adds an unnecessary access RPC before the next
        // original. Detached/process-restored results still need the wake.
        if result.0 == nil { eventSink.yield(()) }
        if lock.withLock({ closing && tasks.isEmpty }) { session.finishTasksAndInvalidate() }
    }
    // Foundation handles background redirects itself; this rejection applies to
    // the Catalyst compiler/fallback session only, not an OS redirect guarantee.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let id = identifier
        Task { @MainActor in BackgroundSessionCompletion.finish(id) }
    }
}

@MainActor
enum BackgroundSessionCompletion {
    private static var handlers: [String: () -> Void] = [:]
    static func store(_ id: String, completion: @escaping () -> Void) { handlers[id] = completion }
    static func finish(_ id: String) { handlers.removeValue(forKey: id)?() }
}
final class CloudifiedAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AutomaticBackupScheduler.shared.register()
        _ = AppEnvironment.shared
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == AppEnvironment.shared.googleBackground?.identifier else { completionHandler(); return }
        BackgroundSessionCompletion.store(identifier, completion: completionHandler)
        AppEnvironment.shared.backgroundTransferWake()
    }
}
