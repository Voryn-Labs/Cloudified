import Foundation

public enum LanePhase: String, Sendable { case checking, preparing, uploading, finalizing }
public struct LaneActivity: Sendable {
    public let jobID: UUID
    public let destinationID: UUID
    public let resourceID: UUID?
    public let phase: LanePhase
    public let attempt: Int
    public let bytes: Int64?
    public let expectedBytes: Int64?
}
public struct LaneResult: Sendable {
    public let provider: Provider
    public let nextWake: Date?
    public let failure: SafeFailure?
    public var requiresRecovery: Bool = false
}
public struct EngineSnapshot: Sendable {
    public let ledger: LedgerSnapshot
    public let active: [Provider: LaneActivity]
    public let paused: Bool
    public let systemGate: KnownCause?
    public let laneFailures: [Provider: SafeFailure]
}

/// Serializes preparation only; provider transfers run outside this actor so both
/// lanes can be active. FIFO waiters are bounded by the two provider workers.
private actor PreparationGate {
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private func acquire() async {
        if !held { held = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    private func release() {
        if waiters.isEmpty { held = false } else { waiters.removeFirst().resume() }
    }
    func prepare(_ preparer: any OriginalPreparer, job: JobRecord, resource: ResourceRequirement,
                 receipts: [RemoteReceipt]) async throws -> [LeasedFile] {
        await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await preparer.prepare(job: job, resource: resource, receipts: receipts)
    }
}

public actor BackupEngine {
    public let ledger: Ledger
    public let files: FileLeaseStore
    private let preparation = PreparationGate()
    private var workers: [Provider: Task<LaneResult, Never>] = [:]
    private var active: [Provider: LaneActivity] = [:]
    private var progressAt: [Provider: Date] = [:]
    private var failures: [Provider: SafeFailure] = [:]
    private var recoveryPending: Set<Provider> = []
    private var transportRecovery: Set<Provider> = []
    private let onDiagnosticFailure: @Sendable (SafeFailure) -> Void
    private var paused = false
    private var systemGate: KnownCause?
    private var batchID: UUID?
    private var batchCancelled = false
    private var batchRunning = false
    private var batchWork: [Provider: @Sendable () async -> LaneResult] = [:]
    private var batchResults: [Provider: LaneResult] = [:]
    private var batchCompletion: CheckedContinuation<[LaneResult], Never>?
    private var laneFinished: (@Sendable (LaneResult) async -> Void)?
    public init(ledger: Ledger, files: FileLeaseStore,
                onDiagnosticFailure: @escaping @Sendable (SafeFailure) -> Void = { _ in }) {
        self.ledger = ledger; self.files = files; self.onDiagnosticFailure = onDiagnosticFailure
    }
    /// Stop new claims before native inventory; existing lanes join at a job
    /// boundary and laneEnded delivers the deferred recovery request.
    public func requestRecoveryAdmission(_ provider: Provider) -> Bool {
        recoveryPending.insert(provider)
        return workers[provider] == nil
    }
    public func finishRecoveryAdmission(_ provider: Provider) { recoveryPending.remove(provider) }

    public func snapshot() async throws -> EngineSnapshot {
        EngineSnapshot(ledger: try await ledger.snapshot(), active: active, paused: paused, systemGate: systemGate, laneFailures: failures)
    }
    public func pause() async throws {
        paused = true
        for task in workers.values { task.cancel() }
        try await ledger.appendEvent(.pause, context: EventContext(), decision: .wait)
    }
    public func resume() async throws {
        paused = false
        for provider in Provider.allCases {
            if let destination = try await ledger.selectedDestination(provider) { try await ledger.wakeWaiting(destinationID: destination.id) }
        }
        try await ledger.appendEvent(.resume, context: EventContext(), decision: .reconcile)
    }
    /// P6 network/thermal/lifecycle controller supplies truthful gate reasons.
    /// Changing policy cancels active work; adapter returns terminal/retained proof.
    public func setSystemGate(_ cause: KnownCause?) async throws {
        systemGate = cause
        if cause != nil { for task in workers.values { task.cancel() } }
        try await ledger.appendEvent(.network, context: EventContext(), decision: cause == nil ? .reconcile : .wait)
    }
    public func setEnabled(destinationID: UUID, enabled: Bool) async throws {
        try await ledger.setEnabled(destinationID, enabled)
        if enabled { try await ledger.wakeWaiting(destinationID: destinationID) }
        if !enabled {
            for (provider, activity) in active where activity.destinationID == destinationID { workers[provider]?.cancel() }
        }
    }
    /// Settings must settle the old worker before replacing/removing credentials.
    /// Durable retained transport IDs additionally require real adapter inventory;
    /// this method does not claim a cancellation request is terminal ownership.
    public func settleProvider(_ provider: Provider) async -> LaneResult? {
        guard let worker = workers[provider] else { return nil }
        worker.cancel()
        return await worker.value
    }
    /// Finite drain of currently-ready work. Returns retry deadlines to one P6
    /// event-driven wake timer; no polling/sleep loop or provider-drain sequencing.
    /// Caller must not end a system background task while retained transfers exist.
    public func runReadyBatch(adapters: [any ProviderAdapter], preparer: any OriginalPreparer,
                             source: (any SourceWorkProducer)? = nil,
                             onLaneFinished: (@Sendable (LaneResult) async -> Void)? = nil) async throws -> [LaneResult] {
        guard !batchRunning, !paused, systemGate == nil, !adapters.isEmpty,
              Set(adapters.map(\.provider)).count == adapters.count else { throw CoreError.invalidTransition }
        batchRunning = true
        let id = UUID(); batchID = id; batchCancelled = false
        defer { batchRunning = false; batchID = nil; batchCancelled = false; batchWork.removeAll(); batchResults.removeAll(); laneFinished = nil }
        let runID = try await ledger.beginRun()
        failures.removeAll(); laneFinished = onLaneFinished
        for adapter in adapters {
            guard let destination = try await ledger.selectedDestination(adapter.provider) else { continue }
            batchWork[adapter.provider] = { await self.runLane(adapter, destination: destination, preparer: preparer, source: source, runID: runID) }
        }
        if batchWork.isEmpty { try await ledger.endRun(runID, needsAttention: false); return [] }
        // All workers are installed in one actor turn before any is awaited.
        let results: [LaneResult] = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                batchCompletion = continuation
                if Task.isCancelled { batchCancelled = true }
                for provider in Provider.allCases where batchWork[provider] != nil { startLane(provider) }
                if workers.isEmpty { batchCompletion = nil; continuation.resume(returning: []) }
            }
        } onCancel: {
            Task { await self.cancelBatch(id) }
        }
        try await ledger.endRun(runID, needsAttention: results.contains { $0.failure != nil })
        return results
    }
    private func cancelBatch(_ id: UUID) {
        guard batchID == id else { return }
        batchCancelled = true
        for worker in workers.values { worker.cancel() }
    }
    /// An existing batch may restart only an idle lane, using the SAME frozen
    /// destination/source generation. New mappings enter a subsequent batch.
    public func wakeReadyLanes() {
        guard batchRunning, !batchCancelled, batchCompletion != nil, !paused, systemGate == nil else { return }
        for provider in Provider.allCases where workers[provider] == nil && batchWork[provider] != nil { startLane(provider) }
    }
    private func startLane(_ provider: Provider) {
        guard !batchCancelled, let work = batchWork[provider], workers[provider] == nil, !recoveryPending.contains(provider) else { return }
        workers[provider] = Task {
            let result = await work()
            await self.finishedLane(result)
            return result
        }
    }
    private func finishedLane(_ result: LaneResult) async {
        workers.removeValue(forKey: result.provider); batchResults[result.provider] = result
        await laneFinished?(result)
        // Callback may have admitted a genuine wake. Never drop a new reader.
        if workers.isEmpty, let continuation = batchCompletion {
            batchCompletion = nil
            continuation.resume(returning: Provider.allCases.compactMap { batchResults[$0] })
        }
    }
    private func runnable(_ destination: UUID) async throws -> Bool {
        guard !paused, systemGate == nil, !Task.isCancelled else { return false }
        return try await ledger.canRun(destination)
    }
    private func runLane(_ adapter: any ProviderAdapter, destination: Destination, preparer: any OriginalPreparer,
                         source: (any SourceWorkProducer)?, runID: UUID) async -> LaneResult {
        let provider = adapter.provider
        var destinationID: UUID?
        defer { active.removeValue(forKey: provider); progressAt.removeValue(forKey: provider); transportRecovery.remove(provider) }
        do {
            destinationID = destination.id
            try await ledger.appendEvent(.laneStart, context: EventContext(runID: runID, origin: provider.origin, destinationID: destination.id), decision: .proceed)
            while try await runnable(destination.id) {
                if recoveryPending.contains(provider) { break }
                guard await adapter.canAcceptWork else { break }
                if let job = try await ledger.claimNext(destinationID: destination.id, runID: runID) {
                    guard try await adapter.canAdmit(job) else {
                        try await ledger.releaseClaim(jobID: job.id)
                        break
                    }
                    try await process(job, adapter: adapter, preparer: preparer, source: source, runID: runID)
                } else if let source, try await source.produceNext(for: destination) {
                    // Producer admission is finite and cursor-backed. A failed
                    // source advances too; it cannot trap this lane on one asset.
                    continue
                } else { break }
            }
            try await ledger.appendEvent(.laneEnd, context: EventContext(runID: runID, origin: provider.origin, destinationID: destination.id), decision: .wait)
            return LaneResult(provider: provider, nextWake: try await ledger.nextWake(destinationID: destination.id), failure: nil,
                              requiresRecovery: transportRecovery.contains(provider))
        } catch {
            if error is CancellationError { return LaneResult(provider: provider, nextWake: nil, failure: nil, requiresRecovery: transportRecovery.contains(provider)) }
            let failure = Self.safe(error)
            failures[provider] = failure
            // DB failure cannot reliably log to that DB. In-memory safe failure is
            // exposed by EngineSnapshot; P5 also records it in OSLog without SQL.
            try? await ledger.appendEvent(.databaseFailure, context: EventContext(runID: runID, origin: provider.origin, destinationID: destinationID), decision: .reconcile, severity: .error, failure: failure)
            return LaneResult(provider: provider, nextWake: nil, failure: failure, requiresRecovery: transportRecovery.contains(provider))
        }
    }
    private func update(_ job: JobRecord, resource: UUID?, phase: LanePhase, bytes: Int64? = nil, expected: Int64? = nil) {
        active[job.destination.provider] = LaneActivity(jobID: job.id, destinationID: job.destination.id, resourceID: resource,
                                                        phase: phase, attempt: job.attempts, bytes: bytes, expectedBytes: expected)
    }
    private func process(_ initial: JobRecord, adapter: any ProviderAdapter, preparer: any OriginalPreparer,
                         source: (any SourceWorkProducer)?, runID: UUID) async throws {
        let provider = adapter.provider
        defer { active.removeValue(forKey: provider); progressAt.removeValue(forKey: provider) }
        update(initial, resource: nil, phase: .checking)
        for resource in try await ledger.missingResources(for: initial.id) {
            guard try await runnable(initial.destination.id) else {
                try await ledger.deferPreparation(jobID: initial.id, failure: SafeFailure(.connectivity, domain: .core, cause: .interrupted), permanent: false, runID: runID)
                return
            }
            let presence = await adapter.inspect(destination: initial.destination, resource: resource)
            try await ledger.applyPresence(presence, jobID: initial.id, resourceID: resource.id, runID: runID)
            switch presence {
            case .unknown, .destinationBlocked: return
            case .present, .verifiedAbsent: break
            }
        }
        var job = try await ledger.finishChecks(jobID: initial.id, runID: runID)
        guard job.state == .ready else { return }
        let missing = try await ledger.missingResources(for: job.id)
        var started = false
        for resource in missing {
            guard try await runnable(job.destination.id) else {
                if started { try await ledger.failAttempt(jobID: job.id, failure: UploadFailure(SafeFailure(.connectivity, domain: .core, cause: .interrupted), disposition: .waiting, acceptance: .definitelyNotAccepted, didStartTransfer: false), runID: runID) }
                else { try await ledger.deferPreparation(jobID: job.id, failure: SafeFailure(.connectivity, domain: .core, cause: .interrupted), permanent: false, runID: runID) }
                return
            }
            update(job, resource: resource.id, phase: .preparing)
            try await ledger.appendEvent(.preparation, context: EventContext(runID: runID, origin: provider.origin, destinationID: job.destination.id, jobID: job.id, resourceID: resource.id, cycleID: job.cycleID, attempt: job.attempts), decision: .proceed)
            let prepared: [LeasedFile]
            do {
                let receipts = try await ledger.receipts(for: job.id)
                prepared = try await preparation.prepare(preparer, job: job, resource: resource, receipts: receipts)
            } catch {
                let failure = Self.safe(error)
                let permanent = failure.category == .unsupportedOriginal || failure.category == .sourceUnavailable || failure.category == .invariant
                if started { try await ledger.failAttempt(jobID: job.id, failure: UploadFailure(failure, disposition: permanent ? .permanent : .waiting, acceptance: .definitelyNotAccepted, didStartTransfer: false), runID: runID) }
                else { try await ledger.deferPreparation(jobID: job.id, failure: failure, permanent: permanent, runID: runID) }
                return
            }
            let transferID = UUID()
            do {
                if resource.role == .manifest {
                    guard prepared.count == 1, prepared[0].byteCount <= 1_048_576 else { throw CoreError.invalidContract }
                } else {
                    guard prepared.map(\.byteCount) == resource.originals.map(\.byteCount) else { throw CoreError.invalidContract }
                }
                guard try await runnable(job.destination.id) else { throw CancellationError() }
                try await files.hold(files: prepared, transferID: transferID, job: job, resourceID: resource.id)
                if !started { job = try await ledger.beginAttempt(jobID: job.id, runID: runID); started = true }
                try await ledger.willSend(jobID: job.id, resourceID: resource.id, runID: runID)
            } catch {
                // No adapter has been invoked, so ownership is genuinely terminal.
                try? await files.transportFinished(transferID)
                try await releasePrepared(prepared)
                if try await ledger.job(job.id).state == .confirmed { return }
                if error is CancellationError {
                    if started {
                            try await ledger.failAttempt(jobID: job.id, failure: UploadFailure(Self.safe(error), disposition: .waiting, acceptance: .definitelyNotAccepted, didStartTransfer: false), runID: runID)
                    } else { try await ledger.deferPreparation(jobID: job.id, failure: Self.safe(error), permanent: false, runID: runID) }
                    return
                }
                if let core = error as? CoreError {
                    if case .invalidTransition = core, !(try await runnable(job.destination.id)) {
                        let safe = SafeFailure(.connectivity, domain: .core, cause: .interrupted)
                        if started {
                            try await ledger.failAttempt(jobID: job.id, failure: UploadFailure(safe, disposition: .waiting, acceptance: .definitelyNotAccepted, didStartTransfer: false), runID: runID)
                        } else { try await ledger.deferPreparation(jobID: job.id, failure: safe, permanent: false, runID: runID) }
                        return
                    }
                    switch core {
                    case .invalidContract, .invalidTransition, .recoveryRequired, .staleMapping, .stagedUnavailable:
                        let safe = Self.safe(error)
                        if started {
                            try await ledger.failAttempt(jobID: job.id, failure: UploadFailure(safe, disposition: .permanent, acceptance: .definitelyNotAccepted), runID: runID)
                        } else { try await ledger.deferPreparation(jobID: job.id, failure: safe, permanent: true, runID: runID) }
                        return
                    case .persistence: break
                    }
                }
                throw error
            }
            update(job, resource: resource.id, phase: .uploading, bytes: 0,
                   expected: prepared.reduce(Int64(0)) { $0 + $1.byteCount })
            let currentJob = job
            // Planning exports and hashes into staging, and prepare() reuses that
            // file. Joined only after this outcome is durable; an early exit cancels it.
            let prefetchSource = adapter.prefetchesNextOriginal && resource.id == missing.last?.id ? source : nil
            let prefetchDestination = job.destination
            async let prefetched = Self.prefetch(prefetchSource, destination: prefetchDestination)
            let outcome = await adapter.upload(job: job, resource: resource, files: prepared, transferID: transferID) { progress in
                await self.progress(progress, job: currentJob, runID: runID)
            }
            let ownership: InputOwnership
            switch outcome {
            case .submitted: ownership = .retainedByTransport
            case .confirmed(_, let value), .failed(_, let value): ownership = value
            }
            if case .failed = outcome, case .retainedByTransport = ownership { transportRecovery.insert(provider) }
            if let bytes = active[provider]?.bytes,
               let failure = await ledger.appendProgress(context: EventContext(runID: runID, origin: provider.origin,
                    destinationID: job.destination.id, jobID: job.id, resourceID: resource.id,
                    cycleID: job.cycleID, attempt: job.attempts), bytes: bytes,
                    expectedBytes: active[provider]?.expectedBytes, force: true) { onDiagnosticFailure(failure) }
            // Transport owns durable holds; runtime worker references can leave.
            // If any persistence step fails, holds survive rather than risk cleanup.
            do {
                switch outcome {
                case .submitted:
                    try await ledger.recordSubmission(jobID: job.id, resourceID: resource.id, transferID: transferID, runID: runID)
                case .confirmed(let receipt, _):
                    update(job, resource: resource.id, phase: .finalizing)
                    try await ledger.appendEvent(.finalization, context: EventContext(runID: runID, origin: provider.origin, destinationID: job.destination.id, jobID: job.id, resourceID: resource.id, cycleID: job.cycleID, attempt: job.attempts), decision: .proceed)
                    try await ledger.confirm(receipt, jobID: job.id, resourceID: resource.id, runID: runID)
                case .failed(let failure, _):
                    // A still-live transport can accept bytes later. Do not trust
                    // an adapter's contradictory claim of definitive absence.
                    let classified: UploadFailure
                    if case .retainedByTransport = ownership {
                        classified = UploadFailure(failure.error, disposition: failure.disposition, acceptance: .unknown, retryAfter: failure.retryAfter)
                    } else { classified = failure }
                    try await ledger.failAttempt(jobID: job.id, failure: classified, runID: runID, resourceID: resource.id, transferID: transferID)
                }
                if case .terminal = ownership { try await files.transportFinished(transferID) }
                try await releasePrepared(prepared)
            } catch {
                for file in prepared { try? await files.release(file) }
                throw error
            }
            // Returning cancels and joins the structured child immediately on
            // failure; recovery must not wait for an unrelated original export.
            if case .failed = outcome { return }
            if case .submitted = outcome { return }
            _ = await prefetched
        }
    }
    private static func prefetch(_ source: (any SourceWorkProducer)?, destination: Destination) async -> Bool {
        guard let source else { return false }
        return await source.prefetch(for: destination)
    }
    private func releasePrepared(_ prepared: [LeasedFile]) async throws {
        var first: (any Error)?
        for file in prepared {
            do { try await files.release(file) } catch { if first == nil { first = error } }
        }
        if let first { throw first }
    }
    private func progress(_ progress: TransferProgress, job: JobRecord, runID: UUID) async {
        let provider = job.destination.provider
        guard let current = active[provider], current.jobID == job.id, current.resourceID == progress.resourceID,
              progress.bytes >= 0, progress.expectedBytes.map({ $0 >= progress.bytes }) ?? true else { return }
        let now = Date()
        if let last = progressAt[provider], now.timeIntervalSince(last) < 0.5 { return }
        progressAt[provider] = now
        update(job, resource: progress.resourceID, phase: .uploading, bytes: progress.bytes, expected: progress.expectedBytes)
        if let failure = await ledger.appendProgress(context: EventContext(runID: runID, origin: provider.origin,
            destinationID: job.destination.id, jobID: job.id, resourceID: progress.resourceID,
            cycleID: job.cycleID, attempt: job.attempts), bytes: progress.bytes, expectedBytes: progress.expectedBytes) {
            onDiagnosticFailure(failure)
        }
    }
    private static func safe(_ error: any Error) -> SafeFailure {
        if let safe = error as? SafeFailure { return safe }
        if case CoreError.persistence(let code) = error { return SafeFailure(.invariant, domain: .sqlite, code: Int(code), cause: .persistenceFailed) }
        if error is CancellationError { return SafeFailure(.connectivity, domain: .core, cause: .interrupted) }
        return SafeFailure(.invariant, domain: .core, cause: .invalidContract)
    }
}
