import Foundation
@preconcurrency import Photos
import os
import CloudifiedCore

/// Demand-driven planning; both providers use one verified source recipe and cache.
public final class PhotoLibraryPipeline: PhotoLibraryAdapterProtocol, Sendable {
    private let ledger: Ledger
    private let fileStore: FileLeaseStore
    private let storageLayout: StorageLayout
    private let permit: SharedExportPermit
    private let exporter: PhotoResourceExporter
    private let preparer: PhotoLibraryOriginalPreparer
    private let onDiagnosticFailure: @Sendable (SafeFailure) -> Void
    public var originalPreparer: any OriginalPreparer { preparer }

    public init(ledger: Ledger, fileStore: FileLeaseStore, storageLayout: StorageLayout,
                permit: SharedExportPermit = .shared, exporter: PhotoResourceExporter = .shared,
                onDiagnosticFailure: @escaping @Sendable (SafeFailure) -> Void = { _ in }) {
        self.ledger = ledger; self.fileStore = fileStore; self.storageLayout = storageLayout
        self.permit = permit; self.exporter = exporter
        self.onDiagnosticFailure = onDiagnosticFailure
        preparer = PhotoLibraryOriginalPreparer(ledger: ledger, fileStore: fileStore,
            storageLayout: storageLayout, permit: permit, exporter: exporter, onDiagnosticFailure: onDiagnosticFailure)
    }
    /// Prefetch keeps one more original staged next to the one uploading. This
    /// is only an early filter; actual reservation can still refuse staging.
    static let prefetchFreeSpace: Int64 = 4 * 1_073_741_824
    public func hasRoomForPrefetch() -> Bool {
        guard !ProcessInfo.processInfo.isLowPowerModeEnabled,
              ProcessInfo.processInfo.thermalState != .serious,
              ProcessInfo.processInfo.thermalState != .critical else { return false }
        return ((try? storageLayout.availableCapacity()) ?? 0) >= Self.prefetchFreeSpace
    }
    public func scanLibrary(full: Bool = true, progress: (@Sendable (Int, Int) -> Void)? = nil) async throws -> (scanID: UUID, totalDiscovered: Int) {
        try await PhotoKitScanner.scanAccessibleLibrary(ledger: ledger, full: full, progress: progress)
    }

    private struct Candidate: Sendable {
        let resource: PHAssetResource
        let selectorIndex: Int
    }
    private struct Measurement: Sendable {
        var originals: [SourceResourceDescriptor] = []
        var splits: [VideoSplitRecipe] = []
        var failures: [(role: ResourceRole, error: SafeFailure)] = []
        var telegramSplitFailure: SafeFailure?
    }

    public func planAsset(asset: AssetIdentity, googleDestination: Destination? = nil,
        telegramDestination: Destination? = nil, googleLiveFallback: LivePhotoFallbackOption = .nativePair,
        videoPartThreshold: Int64 = LosslessVideoPartSplitter.defaultTargetPartSize
    ) async throws {
        try await planAsset(asset: asset, googleDestination: googleDestination,
            telegramDestination: telegramDestination, googleLiveFallback: googleLiveFallback,
            videoPartThreshold: videoPartThreshold, speculative: false)
    }

    private func planAsset(asset: AssetIdentity, googleDestination: Destination?,
        telegramDestination: Destination?, googleLiveFallback: LivePhotoFallbackOption,
        videoPartThreshold: Int64, speculative: Bool
    ) async throws {
        let destinations = [googleDestination, telegramDestination].compactMap { $0 }
        guard !destinations.isEmpty else { return }
        guard (1...LosslessVideoPartSplitter.defaultTargetPartSize).contains(videoPartThreshold),
              googleDestination?.provider != .telegram, telegramDestination?.provider != .google else {
            throw CoreError.invalidContract
        }
        try Task.checkCancellation()
        let phAsset: PHAsset
        let candidates: [Candidate]
        do {
            guard let fetched = PHAsset.fetchAssets(withLocalIdentifiers: [asset.localIdentifier], options: PhotoKitScanner.originalFetchOptions()).firstObject else {
                throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)
            }
            try PhotoKitScanner.verifyGeneration(asset)
            phAsset = fetched
            // Preserve PhotoKit enumeration order within an identical descriptor group.
            // A refetch may change it; descriptor and byte verification still fence reuse.
            var groups: [SourceSelectorKey: Int] = [:]
            candidates = PHAssetResource.assetResources(for: fetched).compactMap { resource in
                guard PhotoKitScanner.isOriginalResourceType(resource.type) else { return nil }
                let key = SourceSelectorKey(type: resource.type.rawValue,
                    filename: resource.originalFilename, uti: resource.uniformTypeIdentifier)
                let index = groups[key, default: 0]; groups[key] = index + 1
                return Candidate(resource: resource, selectorIndex: index)
            }.sorted { lhs, rhs in
                let a = lhs.resource, b = rhs.resource
                return (a.type.rawValue, a.originalFilename, a.uniformTypeIdentifier, lhs.selectorIndex) <
                    (b.type.rawValue, b.originalFilename, b.uniformTypeIdentifier, rhs.selectorIndex)
            }
            guard !candidates.isEmpty else { throw SafeFailure(.unsupportedOriginal, domain: .photos, cause: .formatRejected) }
        } catch let failure as SafeFailure {
            if speculative { throw failure }
            try await record(failure, asset: asset, destinations: destinations)
            throw failure
        }
        let isLive = phAsset.mediaSubtypes.contains(.photoLive)
        let location = phAsset.location.map {
            SourceLocationMetadata(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                altitude: $0.altitude, timestamp: $0.timestamp)
        }
        let metadata = SourceAssetMetadata(creationDate: phAsset.creationDate, modificationDate: phAsset.modificationDate,
            pixelWidth: phAsset.pixelWidth, pixelHeight: phAsset.pixelHeight,
            durationSeconds: phAsset.duration > 0 ? phAsset.duration : nil,
            isFavorite: phAsset.isFavorite, location: location)
        let previous: SourceRecipe?
        if let data = try await ledger.sourceRecipe(assetID: asset.id) {
            let decoded = try SourceRecipe.decode(from: data)
            guard decoded.generation == asset.generation, decoded.assetLocalIdentifier == asset.localIdentifier,
                  decoded.mediaKind == asset.kind, decoded.isLivePhoto == isLive else {
                throw CoreError.invalidContract
            }
            previous = decoded
        } else { previous = nil }
        let copies = destinations.count
        let measured: Measurement
        if let previous, canReuse(previous, candidates: candidates,
            needsTelegram: telegramDestination != nil, threshold: videoPartThreshold) {
            measured = Measurement(originals: previous.resources, splits: previous.videoSplits)
            try await ledger.appendEvent(.preparation, context: EventContext(origin: .source, assetID: asset.id), decision: .skip)
        } else {
            measured = try await permit.withPermit {
                var result = Measurement()
                for candidate in candidates {
                    try Task.checkCancellation()
                    guard let role = PhotoKitScanner.role(for: candidate.resource.type) else { throw CoreError.invalidContract }
                    if telegramDestination == nil && !Self.googleRequires(role, isLive: isLive, fallback: googleLiveFallback) {
                        continue
                    }
                    let leased: LeasedFile
                    let descriptor: SourceResourceDescriptor
                    do {
                        // Startup inventory must have completed. Idle files are re-exportable;
                        // readers/transport holds are protected by the store's deletion fence.
                        let known = previous?.resources.first { Self.matches($0, candidate: candidate) }
                        (descriptor, leased) = try await measure(candidate, asset: asset, copyCount: copies, known: known)
                    } catch {
                        if speculative { throw error }
                        try SourceFailurePolicy.propagateControl(error)
                        result.failures.append((role, SourceFailurePolicy.safe(error, domain: .photos)))
                        continue
                    }
                    // Never let a Telegram-only split error erase this verified Google input.
                    result.originals.append(descriptor)
                    do {
                        if telegramDestination != nil, descriptor.byteCount > videoPartThreshold {
                            try await ledger.appendEvent(.preparation,
                                context: EventContext(origin: .source, destinationID: telegramDestination?.id, assetID: asset.id),
                                decision: .proceed)
                            do {
                                let split = try LosslessVideoPartSplitter.planSplit(fileURL: leased.url,
                                    totalBytes: descriptor.byteCount, role: role, originalSha256: descriptor.sha256,
                                    targetPartSize: videoPartThreshold)
                                if !result.splits.contains(where: { $0.originalSha256 == split.originalSha256 && $0.role == split.role }) {
                                    result.splits.append(split)
                                }
                            } catch {
                                if speculative { throw error }
                                let failure = SourceFailurePolicy.safe(error, domain: .fileSystem)
                                try await ledger.appendEvent(.failure,
                                    context: EventContext(origin: .source, destinationID: telegramDestination?.id, assetID: asset.id),
                                    decision: .wait, severity: .error, failure: failure)
                                try SourceFailurePolicy.propagateControl(error)
                                result.telegramSplitFailure = result.telegramSplitFailure ?? failure
                            }
                            if result.telegramSplitFailure == nil {
                                try await ledger.appendEvent(.preparation, context: EventContext(origin: .source, assetID: asset.id),
                                    decision: .proceed, bytes: descriptor.byteCount)
                            }
                        }
                    } catch {
                        // Release on every split/cancellation/diagnostic failure.
                        do { try await fileStore.release(leased) } catch { throw error }
                        throw error
                    }
                    try await fileStore.release(leased)
                }
                return result
            }
        }
        guard !measured.originals.isEmpty else {
            let failure = measured.failures.first?.error ?? SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)
            if speculative { throw failure }
            try await record(failure, asset: asset, destinations: destinations)
            throw failure
        }
        // Plain recipe is sufficient for Google even when Telegram exceeds part/manifest limits.
        var recipe = try SourceRecipe(assetLocalIdentifier: asset.localIdentifier, generation: asset.generation,
            mediaKind: asset.kind, isLivePhoto: isLive, resources: measured.originals, metadata: metadata)
        var telegramFailure = measured.failures.first?.error ?? measured.telegramSplitFailure
        if telegramDestination != nil, telegramFailure == nil {
            if isLive && !(measured.originals.contains { $0.role == .still } && measured.originals.contains { $0.role == .motion }) {
                telegramFailure = SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)
            } else {
                do {
                    recipe = try SourceRecipe(assetLocalIdentifier: asset.localIdentifier, generation: asset.generation,
                        mediaKind: asset.kind, isLivePhoto: isLive, resources: measured.originals,
                        metadata: metadata, videoSplits: measured.splits)
                } catch {
                    // Base recipe already validated; this additional coverage exceeds
                    // the archive recipe contract, not Google's original-byte plan.
                    telegramFailure = SafeFailure(.unsupportedOriginal, domain: .photos, cause: .formatRejected)
                }
            }
        }
        try await ledger.saveSourceRecipe(assetID: asset.id, json: recipe.encode())
        var enqueued = false
        var firstFailure: SafeFailure?
        if let destination = googleDestination {
            do {
                if let failure = measured.failures.first(where: {
                    Self.googleRequires($0.role, isLive: isLive, fallback: googleLiveFallback)
                })?.error { throw failure }
                let plan = try UploadPlanProducer.buildGooglePlan(recipe: recipe, livePhotoFallback: googleLiveFallback)
                try await ledger.enqueue(assetID: asset.id, destinationID: destination.id, plan: plan)
                enqueued = true
            } catch {
                if speculative { throw error }
                try SourceFailurePolicy.propagateControl(error)
                let failure = SourceFailurePolicy.safe(error, domain: .photos)
                firstFailure = failure
                try await record(failure, asset: asset, destinations: [destination])
            }
        }
        if let destination = telegramDestination {
            do {
                if let telegramFailure { throw telegramFailure }
                guard measured.originals.count == candidates.count else { throw CoreError.invalidContract }
                let plan = try UploadPlanProducer.buildTelegramPlan(recipe: recipe)
                try await ledger.enqueue(assetID: asset.id, destinationID: destination.id, plan: plan)
                enqueued = true
            } catch {
                if speculative { throw error }
                try SourceFailurePolicy.propagateControl(error)
                let failure = SourceFailurePolicy.safe(error, domain: .photos)
                firstFailure = firstFailure ?? failure
                try await record(failure, asset: asset, destinations: [destination])
            }
        }
        if !enqueued { throw firstFailure ?? CoreError.invalidContract }
    }

    private static func googleRequires(_ role: ResourceRole, isLive: Bool, fallback: LivePhotoFallbackOption) -> Bool {
        guard isLive else { return true }
        switch fallback {
        case .keyImageOnly: return role != .motion
        case .motionVideoOnly: return role == .motion
        case .bothSeparately, .nativePair: return true
        }
    }
    private func record(_ failure: SafeFailure, asset: AssetIdentity, destinations: [Destination]) async throws {
        try await ledger.recordSourceFailure(assetID: asset.id, destinationIDs: destinations.map(\.id), error: failure,
            permanent: failure.category == .unsupportedOriginal || failure.cause == .sourceMissing)
    }

    private static func matches(_ descriptor: SourceResourceDescriptor, candidate: Candidate) -> Bool {
        descriptor.role == PhotoKitScanner.role(for: candidate.resource.type) &&
        descriptor.resourceType == candidate.resource.type.rawValue &&
        descriptor.selectorIndex == candidate.selectorIndex &&
        descriptor.uti == candidate.resource.uniformTypeIdentifier &&
        descriptor.originalFilename == candidate.resource.originalFilename
    }
    private func canReuse(_ recipe: SourceRecipe, candidates: [Candidate], needsTelegram: Bool, threshold: Int64) -> Bool {
        guard recipe.resources.count == candidates.count,
              candidates.allSatisfy({ candidate in recipe.resources.contains { Self.matches($0, candidate: candidate) } }) else { return false }
        return !needsTelegram || recipe.resources.filter { $0.byteCount > threshold }.allSatisfy { original in
            recipe.videoSplits.contains { $0.originalSha256 == original.sha256 && $0.role == original.role &&
                $0.totalByteCount == original.byteCount && $0.targetPartSize == threshold }
        }
    }
    private func measure(_ candidate: Candidate, asset: AssetIdentity, copyCount: Int,
                         known: SourceResourceDescriptor?) async throws -> (SourceResourceDescriptor, LeasedFile) {
        guard let role = PhotoKitScanner.role(for: candidate.resource.type) else { throw CoreError.invalidContract }
        guard !candidate.resource.uniformTypeIdentifier.isEmpty, !candidate.resource.originalFilename.isEmpty else {
            throw SafeFailure(.unsupportedOriginal, domain: .photos, cause: .formatRejected)
        }
        if let known {
            let cached: LeasedFile?
            do { cached = try await fileStore.acquireContent(known.originalContent) }
            catch CoreError.stagedUnavailable { cached = nil }
            if let cached {
                do { _ = try await fileStore.sweepIfInventoried(limit: 100) }
                catch { try await fileStore.release(cached); throw error }
                return (known, cached)
            }
        }
        _ = try await fileStore.sweepIfInventoried(limit: 100)
        let fixed: Int64 = 67_108_864
        let reservation = try await ledger.reserveSourceStorage(availableBytes: storageLayout.availableCapacity(),
            additionalCopyCount: copyCount, fixedOverheadBytes: fixed)
        let ownership: ExportFileOwnership
        do { ownership = try await fileStore.beginExport(fileID: UUID()) }
        catch { try await ledger.releaseReservation(reservation.id); throw error }
        let context = EventContext(origin: .source, assetID: asset.id, resourceID: ownership.fileID)
        let coalescer = SourceProgressCoalescer(ledger: ledger, context: context, onDiagnosticFailure: onDiagnosticFailure)
        var leased: LeasedFile?
        var exportEnded = false
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await ledger.appendEvent(.export, context: context, decision: .proceed)
            let hashes = try await exporter.exportResource(candidate.resource, to: ownership.partialURL,
                onProgress: { coalescer.downloadProgress($0) },
                beforeWrite: { written in
                    try SourceWriteAdmission.check(written: written, cap: reservation.byteCount,
                        additionalCopies: copyCount, fixedOverhead: fixed, layout: self.storageLayout)
                }, afterWrite: { try coalescer.update(bytes: $0) })
            try PhotoKitScanner.verifyGeneration(asset)
            guard hashes.byteCount > 0 else { throw SafeFailure(.unsupportedOriginal, domain: .photos, cause: .formatRejected) }
            if let known {
                guard known.sha256 == hashes.sha256, known.sha1 == hashes.sha1, known.byteCount == hashes.byteCount else {
                    throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .contentChanged)
                }
            }
            try await coalescer.finish(finalBytes: hashes.byteCount)
            try FileManager.default.moveItem(at: ownership.partialURL, to: ownership.publishedURL)
            let resized = try await ledger.reserveStorage(bytes: hashes.byteCount, availableBytes: storageLayout.availableCapacity(),
                transportOverhead: try SourceWriteAdmission.overhead(bytes: hashes.byteCount, copies: copyCount, fixed: fixed),
                writtenBytes: hashes.byteCount, replacing: reservation.id)
            let content = OriginalContent(sha256: hashes.sha256, sha1: hashes.sha1, byteCount: hashes.byteCount, role: role)
            let published = try await fileStore.registerPublished(fileID: ownership.fileID, byteCount: hashes.byteCount,
                reservationID: resized.id, reexportable: true, content: content)
            leased = published
            try await fileStore.endExport(ownership); exportEnded = true
            try await ledger.appendEvent(.export, context: context, decision: .proceed,
                duration: ProcessInfo.processInfo.systemUptime - started, bytes: hashes.byteCount)
            try await ledger.appendEvent(.hashing, context: context, decision: .proceed, bytes: hashes.byteCount)
            return (SourceResourceDescriptor(role: role, uti: candidate.resource.uniformTypeIdentifier,
                originalFilename: candidate.resource.originalFilename, sha256: hashes.sha256, sha1: hashes.sha1,
                byteCount: hashes.byteCount, resourceType: candidate.resource.type.rawValue, selectorIndex: candidate.selectorIndex), published)
        } catch {
            do {
                try await ledger.appendEvent(.failure, context: context, decision: .wait, severity: .error,
                    failure: SourceFailurePolicy.safe(error, domain: .photos))
            } catch { onDiagnosticFailure(SourceFailurePolicy.safe(error, domain: .sqlite)) }
            var cleanupError: (any Error)?
            do { try await coalescer.finish() } catch { cleanupError = error }
            if let leased { do { try await fileStore.release(leased) } catch { cleanupError = error } }
            if !exportEnded {
                do { try await fileStore.rollbackExport(ownership, reservationID: reservation.id) } catch { cleanupError = error }
            }
            let terminalError = cleanupError ?? error
            let failure = SourceFailurePolicy.safe(terminalError, domain: .photos)
            try await ledger.appendEvent(.failure, context: context, decision: .wait, severity: .error, failure: failure,
                duration: ProcessInfo.processInfo.systemUptime - started)
            throw terminalError
        }
    }

    public struct PlanBatchResult: Sendable {
        public let nextCursor: Int64
        public let plannedCount: Int
        public let failedCount: Int
        public let hasMore: Bool
    }
    private func planIsCurrent(_ asset: AssetIdentity, google: Destination?, telegram: Destination?,
                               fallback: LivePhotoFallbackOption, threshold: Int64) async throws -> Bool {
        guard let data = try await ledger.sourceRecipe(assetID: asset.id),
              let recipe = try? JSONDecoder().decode(SourceRecipe.self, from: data),
              recipe.generation == asset.generation, recipe.assetLocalIdentifier == asset.localIdentifier,
              recipe.mediaKind == asset.kind else { return false }
        // Derive coverage from the current recipe/policy rather than trusting a
        // stale "planned" bit. A changed account or fallback must re-plan.
        if let google {
            guard let plan = try? UploadPlanProducer.buildGooglePlan(recipe: recipe, livePhotoFallback: fallback),
                  try await ledger.hasEnqueuedPlan(assetID: asset.id, destinationID: google.id, coverageHash: plan.coverageHash) else { return false }
        }
        if let telegram {
            guard recipe.videoSplits.allSatisfy({ $0.targetPartSize == threshold }),
                  let telegramPlan = try? UploadPlanProducer.buildTelegramPlan(recipe: recipe) else { return false }
            return try await ledger.hasEnqueuedPlan(assetID: asset.id, destinationID: telegram.id, coverageHash: telegramPlan.coverageHash)
        }
        return true
    }
    public func planNextAsset(scanID: UUID, afterCursor: Int64 = 0, googleDestination: Destination? = nil,
        telegramDestination: Destination? = nil, googleLiveFallback: LivePhotoFallbackOption = .nativePair,
        videoPartThreshold: Int64 = LosslessVideoPartSplitter.defaultTargetPartSize,
        speculative: Bool = false
    ) async throws -> PlanBatchResult {
        guard (1...LosslessVideoPartSplitter.defaultTargetPartSize).contains(videoPartThreshold),
              !speculative || (googleDestination != nil && telegramDestination == nil) else {
            throw CoreError.invalidContract
        }
        guard googleDestination != nil || telegramDestination != nil else {
            return PlanBatchResult(nextCursor: afterCursor, plannedCount: 0, failedCount: 0, hasMore: false)
        }
        try Task.checkCancellation()
        let page = try await ledger.scannedAssetPage(scanID: scanID, afterCursor: afterCursor, limit: 1)
        guard let row = page.first else { return PlanBatchResult(nextCursor: afterCursor, plannedCount: 0, failedCount: 0, hasMore: false) }
        var failed = false
        do {
            if try await !planIsCurrent(row.asset, google: googleDestination, telegram: telegramDestination,
                                       fallback: googleLiveFallback, threshold: videoPartThreshold) {
                try await planAsset(asset: row.asset, googleDestination: googleDestination, telegramDestination: telegramDestination,
                    googleLiveFallback: googleLiveFallback, videoPartThreshold: videoPartThreshold, speculative: speculative)
            }
        } catch {
            if speculative { throw error } // No failed row or cursor advancement for an optimization.
            try SourceFailurePolicy.propagateControl(error)
            guard error is SafeFailure else { throw error }
            failed = true // source/provider error has already been durably recorded
        }
        let more = try await !ledger.scannedAssetPage(scanID: scanID, afterCursor: row.cursor, limit: 1).isEmpty
        return PlanBatchResult(nextCursor: row.cursor, plannedCount: failed ? 0 : 1, failedCount: failed ? 1 : 0, hasMore: more)
    }
    public func planScannedBatch(scanID: UUID, afterCursor: Int64 = 0, limit: Int = 1,
        googleDestination: Destination? = nil, telegramDestination: Destination? = nil,
        googleLiveFallback: LivePhotoFallbackOption = .nativePair,
        videoPartThreshold: Int64 = LosslessVideoPartSplitter.defaultTargetPartSize
    ) async throws -> PlanBatchResult {
        guard limit == 1 else { throw CoreError.invalidContract }
        return try await planNextAsset(scanID: scanID, afterCursor: afterCursor, googleDestination: googleDestination,
            telegramDestination: telegramDestination, googleLiveFallback: googleLiveFallback, videoPartThreshold: videoPartThreshold)
    }
}

private struct SourceSelectorKey: Hashable { let type: Int; let filename: String; let uti: String }

enum SourceFailurePolicy {
    static func propagateControl(_ error: any Error) throws {
        if error is CancellationError || error is CoreError { throw error }
        if let failure = error as? SafeFailure, failure.category == .invariant { throw failure }
    }
    static func safe(_ error: any Error, domain: ErrorDomain) -> SafeFailure {
        if let failure = error as? SafeFailure { return failure }
        if error is CancellationError { return SafeFailure(.sourceUnavailable, domain: .photos, cause: .interrupted) }
        if case .persistence(let code) = error as? CoreError {
            return SafeFailure(.invariant, domain: .sqlite, code: Int(code), cause: .persistenceFailed)
        }
        if error is CoreError { return SafeFailure(.invariant, domain: .core, cause: .invalidContract) }
        return SafeFailure(.transfer, domain: domain, code: (error as NSError).code, cause: .unknown)
    }
}

enum SourceWriteAdmission {
    static func overhead(bytes: Int64, copies: Int, fixed: Int64) throws -> Int64 {
        guard bytes >= 0, (0...2).contains(copies), fixed >= 0,
              copies == 0 || bytes <= (Int64.max - fixed) / Int64(copies) else { throw CoreError.invalidContract }
        return fixed + bytes * Int64(copies)
    }
    static func check(written: Int64, cap: Int64, additionalCopies: Int, fixedOverhead: Int64, layout: StorageLayout) throws {
        guard written >= 0, written <= cap else { throw SafeFailure(.diskFull, domain: .fileSystem, cause: .insufficientSpace) }
        let available = try layout.availableCapacity()
        let overhead = try overhead(bytes: written, copies: additionalCopies, fixed: fixedOverhead)
        // The writer calls BEFORE a <=1 MiB slice; leave room for that write,
        // measured-copy allowance and the safety margin without overflow.
        let safety: Int64 = 536_870_912
        guard available >= safety, overhead <= available - safety,
              1_048_576 <= available - safety - overhead else {
            throw SafeFailure(.diskFull, domain: .fileSystem, cause: .insufficientSpace)
        }
    }
}

/// One bounded consumer per export; measured bytes come from afterWrite, never a
/// proposed write or iCloud fraction. All terminal paths close AND await the task.
final class SourceProgressCoalescer: Sendable {
    private struct State: Sendable {
        var bytes: Int64 = 0
        var downloadObserved = false
        var successfulExport = false
        var closed = false
        var persistenceError: (any Error)?
    }
    private let state: OSAllocatedUnfairLock<State>
    private let continuation: AsyncStream<Void>.Continuation
    private let consumer: Task<Void, any Error>
    init(ledger: Ledger, context: EventContext, expectedBytes: Int64? = nil,
         onDiagnosticFailure: @escaping @Sendable (SafeFailure) -> Void = { _ in }) {
        let state = OSAllocatedUnfairLock(initialState: State())
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.state = state; continuation = pair.continuation
        consumer = Task {
            var lastBytes: Int64 = -1
            var downloadLogged = false
            var lastTime: TimeInterval = 0
            do {
                for await _ in pair.stream {
                    let remaining = 0.5 - (ProcessInfo.processInfo.systemUptime - lastTime)
                    if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                    let sample = state.withLock { ($0.bytes, $0.downloadObserved) }
                    if sample.1 && !downloadLogged {
                        try await ledger.appendEvent(.network, context: context, decision: .wait)
                        downloadLogged = true
                    }
                    if sample.0 != lastBytes {
                        if let failure = await ledger.appendProgress(context: context, bytes: sample.0, expectedBytes: expectedBytes) {
                            onDiagnosticFailure(failure)
                        }
                        lastBytes = sample.0
                    }
                    lastTime = ProcessInfo.processInfo.systemUptime
                }
                let final = state.withLock { $0.bytes }
                if let failure = await ledger.appendProgress(context: context, bytes: final, expectedBytes: expectedBytes, force: true) {
                    onDiagnosticFailure(failure)
                }
                if downloadLogged {
                    let succeeded = state.withLock { $0.successfulExport }
                    try await ledger.appendEvent(.network, context: context, decision: succeeded ? .proceed : .wait)
                }
            } catch {
                state.withLock { $0.persistenceError = error; $0.closed = true }
                pair.continuation.finish()
                throw error
            }
        }
    }
    func update(bytes: Int64) throws {
        guard bytes >= 0 else { throw CoreError.invalidContract }
        let accepted = try state.withLock { value -> Bool in
            if let error = value.persistenceError { throw error }
            guard !value.closed else { return false }
            guard bytes >= value.bytes else { throw CoreError.invalidContract }
            value.bytes = bytes; return true
        }
        if accepted { continuation.yield(()) }
    }
    func downloadProgress(_ fraction: Double) {
        guard fraction.isFinite, (0...1).contains(fraction) else { return }
        let accepted = state.withLock { value -> Bool in
            guard !value.closed else { return false }
            value.downloadObserved = true; return true
        }
        if accepted { continuation.yield(()) }
    }
    func finish(finalBytes: Int64? = nil) async throws {
        var finalError: (any Error)?
        do { if let finalBytes { try update(bytes: finalBytes) } } catch { finalError = error }
        let succeeded = finalBytes != nil && finalError == nil
        state.withLock { $0.closed = true; $0.successfulExport = succeeded }
        continuation.finish()
        do { try await consumer.value } catch { if finalError == nil { finalError = error } }
        if let finalError { throw finalError }
    }
}
