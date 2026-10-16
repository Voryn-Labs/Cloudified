import Foundation
import CloudifiedCore

/// One actual planning Task + at most one waiting provider. No whole-library
/// original preparation, no polling, and no provider's network wait in this actor.
actor DemandSourceProducer: SourceWorkProducer {
    let scanID: UUID
    private let pipeline: PhotoLibraryPipeline
    private let policy: LivePhotoFallbackOption
    private let destinations: [Provider: Destination]
    private var cursors: [UUID: Int64]
    private var exhausted: Set<UUID> = []
    private var stopped = false
    private var planning: Task<PhotoLibraryPipeline.PlanBatchResult, any Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let statusContinuation: AsyncStream<Provider?>.Continuation
    nonisolated let statusEvents: AsyncStream<Provider?>

    init(scanID: UUID, pipeline: PhotoLibraryPipeline, destinations: [Destination],
         policy: LivePhotoFallbackOption, cursors: [UUID: Int64]) {
        self.scanID = scanID; self.pipeline = pipeline; self.policy = policy
        self.destinations = Dictionary(uniqueKeysWithValues: destinations.map { ($0.provider, $0) })
        self.cursors = cursors
        let stream = AsyncStream<Provider?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        statusEvents = stream.stream; statusContinuation = stream.continuation
    }
    func produceNext(for destination: Destination) async throws -> Bool {
        try await produceNext(for: destination, speculative: false)
    }
    private func produceNext(for destination: Destination, speculative: Bool) async throws -> Bool {
        while planning != nil && !stopped {
            guard waiters.count < 1 else { throw CoreError.invalidContract }
            await withCheckedContinuation { waiters.append($0) }
            try Task.checkCancellation()
        }
        guard !stopped, destinations[destination.provider]?.id == destination.id,
              !exhausted.contains(destination.id) else { return false }
        try Task.checkCancellation()
        let cursor = cursors[destination.id] ?? 0
        let pipeline = pipeline, scan = scanID, policy = policy
        let task = Task {
            try await pipeline.planNextAsset(scanID: scan, afterCursor: cursor,
                googleDestination: destination.provider == .google ? destination : nil,
                telegramDestination: destination.provider == .telegram ? destination : nil,
                googleLiveFallback: policy, speculative: speculative)
        }
        planning = task; statusContinuation.yield(destination.provider)
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        planning = nil; statusContinuation.yield(nil)
        let queued = waiters; waiters.removeAll(); for waiter in queued { waiter.resume() }
        switch result {
        case .success(let batch):
            cursors[destination.id] = batch.nextCursor
            if !batch.hasMore { exhausted.insert(destination.id) }
            return !stopped && batch.nextCursor > cursor
        case .failure(let error):
            if stopped && error is CancellationError { return false }
            throw error
        }
    }
    func prefetch(for destination: Destination) async -> Bool {
        guard planning == nil, waiters.isEmpty, !stopped, pipeline.hasRoomForPrefetch() else { return false }
        return (try? await produceNext(for: destination, speculative: true)) ?? false
    }
    /// Join before remapping/invalidation; cancellation is not ownership release.
    func stop() async -> [UUID: Int64] {
        stopped = true
        let task = planning; task?.cancel(); _ = await task?.result
        let queued = waiters; waiters.removeAll(); for waiter in queued { waiter.resume() }
        statusContinuation.finish()
        return cursors
    }
    func positions() -> [UUID: Int64] { cursors }
}
