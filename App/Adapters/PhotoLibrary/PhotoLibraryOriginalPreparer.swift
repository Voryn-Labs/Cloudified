import Foundation
@preconcurrency import Photos
import CloudifiedCore

/// Production implementation of OriginalPreparer.
/// Resolves frozen asset recipes, exports originals via PhotoKit, slices lossless video parts,
/// and builds archive manifests while strictly honoring storage admission and lease ownership.
public final class PhotoLibraryOriginalPreparer: OriginalPreparer, Sendable {
    private let ledger: Ledger
    private let fileStore: FileLeaseStore
    private let storageLayout: StorageLayout
    private let permit: SharedExportPermit
    private let exporter: PhotoResourceExporter
    private let onDiagnosticFailure: @Sendable (SafeFailure) -> Void

    public init(
        ledger: Ledger,
        fileStore: FileLeaseStore,
        storageLayout: StorageLayout,
        permit: SharedExportPermit = .shared,
        exporter: PhotoResourceExporter = .shared,
        onDiagnosticFailure: @escaping @Sendable (SafeFailure) -> Void = { _ in }
    ) {
        self.ledger = ledger
        self.fileStore = fileStore
        self.storageLayout = storageLayout
        self.permit = permit
        self.exporter = exporter
        self.onDiagnosticFailure = onDiagnosticFailure
    }

    public func prepare(
        job: JobRecord,
        resource: ResourceRequirement,
        receipts: [RemoteReceipt]
    ) async throws -> [LeasedFile] {
        let context = EventContext(origin: .source, destinationID: job.destination.id,
            jobID: job.id, assetID: job.asset.id, resourceID: resource.id)
        do {
            // All preparations (including manifests) are serialized under the shared permit
            return try await permit.withPermit {
                try await ledger.appendEvent(.preparation, context: context, decision: .proceed)
                // 1. Archive manifests are generated fresh from confirmed receipts; never return a stale cache
                if resource.role == .manifest {
                    return [try await prepareManifest(job: job, resource: resource, receipts: receipts)]
                }

                // Retrieve private durable recipe
                let recipe = try await loadRecipe(job)

                var leasedFiles: [LeasedFile] = []

                do {
                    for original in resource.originals {
                        // Try to acquire from verified cache first; only stagedUnavailable is a clean miss
                        var leased: LeasedFile?
                        do {
                            leased = try await fileStore.acquireContent(original)
                        } catch CoreError.stagedUnavailable {
                            leased = nil
                        }

                        if let leased {
                            leasedFiles.append(leased)
                        } else if let partIndex = original.partIndex {
                            let preparedPart = try await prepareVideoPart(
                                job: job,
                                resourceID: resource.id,
                                original: original,
                                partIndex: partIndex,
                                recipe: recipe
                            )
                            leasedFiles.append(preparedPart)
                        } else {
                            let preparedOriginal = try await exportOriginalResource(
                                job: job,
                                resourceID: resource.id,
                                original: original,
                                recipe: recipe
                            )
                            leasedFiles.append(preparedOriginal)
                        }
                    }
                    return leasedFiles
                } catch {
                    // Retain the preparation cause even if cleanup must take precedence.
                    do {
                        try await ledger.appendEvent(.failure, context: context, decision: .wait, severity: .error,
                            failure: SourceFailurePolicy.safe(error, domain: .photos))
                    } catch { onDiagnosticFailure(SourceFailurePolicy.safe(error, domain: .sqlite)) }
                    var cleanupError: (any Error)?
                    for leased in leasedFiles {
                        do { try await fileStore.release(leased) } catch { cleanupError = error }
                    }
                    throw cleanupError ?? error
                }
            }
        } catch {
            try await ledger.appendEvent(.failure, context: context, decision: .wait, severity: .error,
                failure: SourceFailurePolicy.safe(error, domain: .photos))
            throw error
        }
    }

    private func loadRecipe(_ job: JobRecord) async throws -> SourceRecipe {
        guard let data = try await ledger.sourceRecipe(assetID: job.asset.id) else {
            throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)
        }
        let recipe = try SourceRecipe.decode(from: data)
        guard recipe.assetLocalIdentifier == job.asset.localIdentifier,
              recipe.generation == job.asset.generation, recipe.mediaKind == job.asset.kind else {
            throw CoreError.invalidContract
        }
        return recipe
    }

    // MARK: - Manifest Preparation

    private func prepareManifest(
        job: JobRecord,
        resource: ResourceRequirement,
        receipts: [RemoteReceipt]
    ) async throws -> LeasedFile {
        let recipe = try await loadRecipe(job)

        let media = try UploadPlanProducer.telegramMedia(recipe: recipe)
        let frozenMedia = job.plan.resources.filter { $0.role != .manifest }
        guard media.requirements.map(\.tag) == frozenMedia.map(\.tag),
              media.requirements.map(\.originals) == frozenMedia.map(\.originals),
              media.requirements.map(\.role) == frozenMedia.map(\.role) else { throw CoreError.invalidContract }
        let entries = media.entries

        let destinationReceipts = receipts.filter { $0.destinationID == job.destination.id }
        let requiredTags = Set(entries.map(\.tag))
        guard requiredTags.isSubset(of: Set(destinationReceipts.map(\.tag))) else {
            throw SafeFailure(.invariant, domain: .core, cause: .invalidContract)
        }

        let (manifestData, associationHash) = try ArchiveManifestBuilder.buildManifest(
            kind: recipe.mediaKind,
            isLivePhoto: recipe.isLivePhoto,
            metadata: recipe.metadata,
            originals: recipe.resources,
            resources: entries,
            receipts: destinationReceipts
        )

        let expected = try ContentIdentity.resource(role: .manifest, originals: [], associationHash: associationHash)
        guard expected.tag == resource.tag else { throw CoreError.invalidContract }

        let available = try storageLayout.availableCapacity()
        let manifestOverhead: Int64 = 65_536
        let reservation = try await ledger.reserveStorage(
            bytes: Int64(manifestData.count),
            availableBytes: available,
            transportOverhead: manifestOverhead + Int64(manifestData.count)
        )

        // Manifest uses a fresh physical UUID per document; remote tag remains recipe-derived
        let documentID = UUID()
        let ownership: ExportFileOwnership
        do {
            ownership = try await fileStore.beginExport(fileID: documentID)
        } catch {
            try await ledger.releaseReservation(reservation.id)
            throw error
        }

        var publishedLease: LeasedFile?
        var exportEnded = false
        do {
            try manifestData.write(to: ownership.partialURL)
            try FileManager.default.moveItem(at: ownership.partialURL, to: ownership.publishedURL)
            let leased = try await fileStore.registerPublished(
                fileID: documentID,
                byteCount: Int64(manifestData.count),
                reservationID: reservation.id,
                reexportable: true
            )
            publishedLease = leased
            try await fileStore.endExport(ownership)
            exportEnded = true

            try await ledger.appendEvent(
                .preparation,
                context: EventContext(
                    origin: .source,
                    destinationID: job.destination.id,
                    jobID: job.id,
                    assetID: job.asset.id,
                    resourceID: resource.id
                ),
                decision: .proceed,
                bytes: Int64(manifestData.count)
            )

            return leased
        } catch {
            var cleanupError: (any Error)?
            if let leased = publishedLease {
                do { try await fileStore.release(leased) } catch { cleanupError = error }
            }
            if !exportEnded {
                do { try await fileStore.rollbackExport(ownership, reservationID: reservation.id) }
                catch { cleanupError = error }
            }
            let terminalError = cleanupError ?? error
            try await ledger.appendEvent(.failure,
                context: EventContext(origin: .source, destinationID: job.destination.id, jobID: job.id,
                    assetID: job.asset.id, resourceID: resource.id), decision: .wait, severity: .error,
                failure: SourceFailurePolicy.safe(terminalError, domain: .fileSystem))
            throw terminalError
        }
    }

    // MARK: - Original Media Export

    private func exportOriginalResource(
        job: JobRecord,
        resourceID: UUID,
        original: OriginalContent,
        recipe: SourceRecipe
    ) async throws -> LeasedFile {
        let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [job.asset.localIdentifier], options: PhotoKitScanner.originalFetchOptions())
        guard let phAsset = fetchResult.firstObject else {
            throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)
        }

        // Verify generation before measurement against refetched snapshot
        try PhotoKitScanner.verifyGeneration(job.asset)

        // Match exact source descriptor using role, UTI, original filename, and private selector
        guard let descriptor = recipe.resources.first(where: {
            $0.role == original.role && $0.sha256 == original.sha256 && $0.sha1 == original.sha1 && $0.byteCount == original.byteCount
        }) else {
            throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)
        }

        let resources = PHAssetResource.assetResources(for: phAsset)
        var candidates = resources.filter { res in
            PhotoKitScanner.role(for: res.type) == descriptor.role &&
            res.uniformTypeIdentifier == descriptor.uti &&
            res.originalFilename == descriptor.originalFilename
        }

        if let expectedType = descriptor.resourceType {
            candidates = candidates.filter { $0.type.rawValue == expectedType }
        }

        let matched: PHAssetResource
        if candidates.count == 1 {
            guard descriptor.selectorIndex == nil || descriptor.selectorIndex == 0 else {
                throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .contentChanged)
            }
            matched = candidates[0]
        } else if candidates.count > 1 {
            guard let idx = descriptor.selectorIndex, candidates.indices.contains(idx) else {
                throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .contentChanged)
            }
            matched = candidates[idx]
        } else {
            throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)
        }

        let fileID = try ContentIdentity.stagingFileID(for: original)
        let available = try storageLayout.availableCapacity()
        let copyCount = 2 // shared re-export may feed both independently active providers
        let fixedOverhead: Int64 = 67_108_864
        let transportOverhead = try SourceWriteAdmission.overhead(bytes: original.byteCount, copies: copyCount, fixed: fixedOverhead)
        let reservation = try await ledger.reserveStorage(
            bytes: original.byteCount,
            availableBytes: available,
            transportOverhead: transportOverhead
        )

        let ownership: ExportFileOwnership
        do {
            ownership = try await fileStore.beginExport(fileID: fileID)
        } catch {
            try await ledger.releaseReservation(reservation.id)
            throw error
        }

        var publishedLease: LeasedFile?
        var exportEnded = false
        let context = EventContext(origin: .source, destinationID: job.destination.id,
            jobID: job.id, assetID: job.asset.id, resourceID: resourceID)
        let coalescer = SourceProgressCoalescer(ledger: ledger, context: context, expectedBytes: original.byteCount,
            onDiagnosticFailure: onDiagnosticFailure)
        let started = ProcessInfo.processInfo.systemUptime
        do {
            try await ledger.appendEvent(.export, context: context, decision: .proceed)
            let (sha256, sha1, bytesWritten) = try await exporter.exportResource(
                matched,
                to: ownership.partialURL,
                onProgress: { coalescer.downloadProgress($0) },
                beforeWrite: { written in
                    guard written <= original.byteCount else {
                        throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .contentChanged)
                    }
                    try SourceWriteAdmission.check(written: written, cap: original.byteCount,
                        additionalCopies: copyCount, fixedOverhead: fixedOverhead, layout: self.storageLayout)
                }, afterWrite: { try coalescer.update(bytes: $0) }
            )

            // Verify generation after measurement against refetched snapshot
            try PhotoKitScanner.verifyGeneration(job.asset)

            // Validate byte identity before publication
            guard bytesWritten == original.byteCount,
                  sha256 == original.sha256,
                  sha1 == original.sha1 else {
                throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .contentChanged)
            }

            try await coalescer.finish(finalBytes: bytesWritten)
            try FileManager.default.moveItem(at: ownership.partialURL, to: ownership.publishedURL)
            _ = try await ledger.reserveStorage(bytes: bytesWritten, availableBytes: storageLayout.availableCapacity(),
                transportOverhead: transportOverhead, writtenBytes: bytesWritten, replacing: reservation.id)
            let leased = try await fileStore.registerPublished(
                fileID: fileID,
                byteCount: bytesWritten,
                reservationID: reservation.id,
                reexportable: true,
                content: original
            )
            publishedLease = leased
            try await fileStore.endExport(ownership)
            exportEnded = true

            try await ledger.appendEvent(
                .export,
                context: EventContext(
                    origin: .source,
                    destinationID: job.destination.id,
                    jobID: job.id,
                    assetID: job.asset.id,
                    resourceID: resourceID
                ),
                decision: .proceed,
                bytes: bytesWritten
            )

            try await ledger.appendEvent(.hashing, context: context, decision: .proceed,
                duration: ProcessInfo.processInfo.systemUptime - started, bytes: bytesWritten)
            return leased
        } catch {
            var cleanupError: (any Error)?
            do { try await coalescer.finish() } catch { cleanupError = error }
            if let leased = publishedLease {
                do { try await fileStore.release(leased) } catch { cleanupError = error }
            }
            if !exportEnded {
                do { try await fileStore.rollbackExport(ownership, reservationID: reservation.id) }
                catch { cleanupError = error }
            }
            let terminalError = cleanupError ?? error
            try await ledger.appendEvent(.failure, context: context, decision: .wait, severity: .error,
                failure: SourceFailurePolicy.safe(terminalError, domain: .photos),
                duration: ProcessInfo.processInfo.systemUptime - started)
            throw terminalError
        }
    }

    // MARK: - Video Part Extraction

    private func prepareVideoPart(
        job: JobRecord,
        resourceID: UUID,
        original: OriginalContent,
        partIndex: Int,
        recipe: SourceRecipe
    ) async throws -> LeasedFile {
        guard let split = recipe.videoSplits.first(where: {
            $0.role == original.role && $0.parts.indices.contains(partIndex) &&
            $0.parts[partIndex].originalContent == original
        }), partIndex < split.parts.count else {
            throw SafeFailure(.invariant, domain: .photos, cause: .invalidContract)
        }
        let partDesc = split.parts[partIndex]

        // Locate master original descriptor with exact identity
        guard let masterDesc = recipe.resources.first(where: {
            $0.sha256 == split.originalSha256 && $0.role == split.role && $0.byteCount == split.totalByteCount
        }) else {
            throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)
        }
        let masterOriginal = masterDesc.originalContent

        // Acquire or export master video
        let masterLease: LeasedFile
        do {
            masterLease = try await fileStore.acquireContent(masterOriginal)
        } catch CoreError.stagedUnavailable {
            masterLease = try await exportOriginalResource(
                job: job,
                resourceID: UUID(),
                original: masterOriginal,
                recipe: recipe
            )
        }

        // Track every acquired object, including pre-export failures
        var reservation: StorageReservation?
        var ownership: ExportFileOwnership?
        var publishedLease: LeasedFile?
        var exportEnded = false
        var masterReleased = false
        do {
            _ = try await fileStore.sweepIfInventoried()
            let available = try storageLayout.availableCapacity()
            let copyOverhead = partDesc.byteCount + 67_108_864
            let admitted = try await ledger.reserveStorage(
                bytes: partDesc.byteCount,
                availableBytes: available,
                transportOverhead: copyOverhead,
                derivedFromFileID: masterLease.fileID
            )
            reservation = admitted
            let partFileID = try ContentIdentity.stagingFileID(for: original)
            let exporting = try await fileStore.beginExport(fileID: partFileID)
            ownership = exporting
            let (sha256, sha1, bytesWritten) = try LosslessVideoPartSplitter.extractPart(
                from: masterLease.url, descriptor: partDesc, to: exporting.partialURL,
                beforeWrite: { written in
                    try SourceWriteAdmission.check(written: written, cap: partDesc.byteCount,
                        additionalCopies: 1, fixedOverhead: 67_108_864, layout: self.storageLayout)
                }
            )
            guard bytesWritten == partDesc.byteCount,
                  sha256 == partDesc.sha256, sha1 == partDesc.sha1 else {
                throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .contentChanged)
            }
            try FileManager.default.moveItem(at: exporting.partialURL, to: exporting.publishedURL)
            let leased = try await fileStore.registerPublished(
                fileID: partFileID, byteCount: bytesWritten, reservationID: admitted.id,
                reexportable: true, content: original
            )
            publishedLease = leased
            try await fileStore.endExport(exporting)
            exportEnded = true
            masterReleased = true
            try await fileStore.release(masterLease)
            try await ledger.appendEvent(
                .preparation,
                context: EventContext(origin: .source, destinationID: job.destination.id,
                    jobID: job.id, assetID: job.asset.id, resourceID: resourceID),
                decision: .proceed, bytes: bytesWritten
            )
            return leased
        } catch {
            var cleanupError: (any Error)?
            if let leased = publishedLease {
                do { try await fileStore.release(leased) } catch { cleanupError = error }
            }
            if !exportEnded, let reservation {
                do {
                    if let ownership {
                        try await fileStore.rollbackExport(ownership, reservationID: reservation.id)
                    } else {
                        try await ledger.releaseReservation(reservation.id)
                    }
                } catch { cleanupError = error }
            }
            if !masterReleased {
                do { try await fileStore.release(masterLease) } catch { cleanupError = error }
            }
            throw cleanupError ?? error
        }
    }
}
