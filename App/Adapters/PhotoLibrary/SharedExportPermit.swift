import Foundation
import CloudifiedCore

/// One source operation across planning and both workers. Cancelled queued work
/// removes its continuation immediately; ownership transfers only to live waiters.
public actor SharedExportPermit {
    public static let shared = SharedExportPermit()
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, any Error> }
    private var held = false
    private var waiters: [Waiter] = []
    public init() {}
    private func acquire() async throws {
        try Task.checkCancellation()
        if !held { held = true; return }
        guard waiters.count < 16 else { throw CoreError.invalidContract }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) } // one cancellation notification, never per media chunk
        }
        if Task.isCancelled { release(); throw CancellationError() }
    }
    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release() {
        if waiters.isEmpty { held = false }
        else { waiters.removeFirst().continuation.resume() }
    }
    public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }
}
