import Foundation
@preconcurrency import Photos
import CloudifiedCore

/// Terminal completion or lock-fenced cancellation closes our writer exactly once.
public final class PhotoResourceExporter: Sendable {
    public static let shared = PhotoResourceExporter()
    public init() {}
    public func exportResource(_ resource: PHAssetResource, to destinationURL: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil,
        beforeWrite: (@Sendable (Int64) throws -> Void)? = nil,
        afterWrite: (@Sendable (Int64) throws -> Void)? = nil
    ) async throws -> (sha256: String, sha1: String, byteCount: Int64) {
        let request = ExportRequest(writer: try StreamingFileWriter(fileURL: destinationURL,
            beforeWrite: beforeWrite, afterWrite: afterWrite))
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard request.begin(continuation) else { return }
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true
                options.progressHandler = { value in request.progress(value); onProgress?(value) }
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options,
                    dataReceivedHandler: { request.receive($0) }, completionHandler: { request.complete($0) })
                request.install(id)
            }
        } onCancel: { request.cancel() }
    }
}

/// Every field is lock-protected, including cancellation before request-ID publication.
/// No per-chunk Task, additional callback queue or unbounded media buffer.
private final class ExportRequest: @unchecked Sendable {
    typealias Output = (sha256: String, sha1: String, byteCount: Int64)
    private let lock = NSLock()
    private let writer: StreamingFileWriter
    private var continuation: CheckedContinuation<Output, any Error>?
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelRequested = false
    private var finished = false
    private var firstError: (any Error)?
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var lastProgress = 0.0
    private var watchdog: Task<Void, Never>?
    init(writer: StreamingFileWriter) { self.writer = writer }
    func begin(_ continuation: CheckedContinuation<Output, any Error>) -> Bool {
        lock.lock()
        if cancelRequested {
            finished = true; writer.abort(); lock.unlock()
            continuation.resume(throwing: CancellationError()); return false
        }
        self.continuation = continuation
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self else { return }
                if self.cancelIfStalled() { return }
            }
        }
        lock.unlock(); return true
    }
    func progress(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        if !finished, value.isFinite, value > lastProgress {
            lastProgress = value; lastActivity = ProcessInfo.processInfo.systemUptime
        }
    }
    private func cancelIfStalled() -> Bool {
        lock.lock()
        guard !finished, !cancelRequested else { lock.unlock(); return true }
        guard ProcessInfo.processInfo.systemUptime - lastActivity >= 180 else { lock.unlock(); return false }
        firstError = SafeFailure(.timeout, domain: .photos, cause: .deadlineExceeded)
        cancelRequested = true
        let id = requestID; lock.unlock()
        complete(nil)
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        return true
    }
    func install(_ id: PHAssetResourceDataRequestID) {
        lock.lock(); requestID = id
        let shouldCancel = cancelRequested; lock.unlock()
        if shouldCancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func cancel() {
        lock.lock(); cancelRequested = true
        let id = finished ? nil : requestID; lock.unlock()
        // PhotoKit owns callbacks, never this path. complete fences late writes
        // under the same lock before the caller releases its export ownership.
        complete(nil)
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func receive(_ data: Data) {
        lock.lock()
        guard !finished, !cancelRequested, firstError == nil else { lock.unlock(); return }
        do {
            try writer.write(chunk: data)
            if !data.isEmpty { lastActivity = ProcessInfo.processInfo.systemUptime }
            lock.unlock()
        }
        catch {
            firstError = error; cancelRequested = true
            let id = requestID; lock.unlock()
            complete(nil)
            if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        }
    }
    func complete(_ error: (any Error)?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        watchdog?.cancel(); watchdog = nil
        let continuation = self.continuation; self.continuation = nil
        let result: Result<Output, any Error>
        if let firstError { writer.abort(); result = .failure(firstError) }
        else if cancelRequested { writer.abort(); result = .failure(CancellationError()) }
        else if let error {
            writer.abort()
            // An arbitrary iCloud/network error is not evidence of source deletion.
            result = .failure(SafeFailure(.transfer, domain: .photos, code: (error as NSError).code, cause: .unknown))
        } else {
            do { result = .success(try writer.finalize()) }
            catch { writer.abort(); result = .failure(error) }
        }
        lock.unlock(); continuation?.resume(with: result)
    }
}
