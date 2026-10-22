import Foundation
import CloudifiedCore

private struct GoogleLibraryGate: Error { let underlying: any Error }

extension GooglePhotosProviderAdapter {
    /// Metadata is supporting evidence only. Exact hash/receipt checks still own Saved.
    func checkLibraryCandidate(_ requested: Destination, resource: ResourceRequirement, acceptedOriginals: Set<String> = []) async throws -> SafeFailure? {
        guard let catalogURL else { return nil }
        let scope = requested.verifiedFingerprint
        if catalogScope != scope { catalogRetry = .distantPast; catalogScope = scope }
        let data = try await ledger.googleSourceRecipe(destinationID: requested.id, tag: resource.tag)
        let recipe = try data.map { try SourceRecipe.decode(from: $0) }
        if catalog == nil, Date() >= catalogRetry {
            do { catalog = try GoogleRemoteIndex(url: catalogURL) }
            catch { catalogRetry = Date().addingTimeInterval(3600); await libraryEvent(.googleLibraryUnavailable, requested, failure: ProviderSupport.safe(error, domain: .fileSystem)); return nil }
        }
        guard let catalog else { return nil }
        do {
            var cursor = try await catalog.cursor(scope: scope)
            if !cursor.complete, Date() >= catalogRetry {
                for _ in 0..<2 {
                    try Task.checkCancellation()
                    do {
                        let page = try await readLibraryPage(cursor, destination: requested)
                        cursor = try await catalog.apply(page, expected: cursor)
                        await libraryEvent(.googleLibrarySync, requested, items: page.items.count, pages: cursor.pages)
                        if cursor.complete { break }
                    } catch {
                        if error is CancellationError || error is GoogleLibraryGate { throw error }
                        catalogRetry = Date().addingTimeInterval(3600)
                        await libraryEvent(.googleLibraryUnavailable, requested, failure: ProviderSupport.safe(error, domain: .google))
                        break
                    }
                }
            }
            if try await catalog.isAllowed(scope: scope, tag: resource.tag) { return nil }
            if let recipe {
                if let date = recipe.metadata.creationDate {
                    for original in resource.originals where !acceptedOriginals.contains(original.sha256) {
                        guard let source = recipe.resources.first(where: { $0.sha256 == original.sha256 && $0.sha1 == original.sha1 && $0.byteCount == original.byteCount }) else { continue }
                        let candidate = try await catalog.candidate(scope: scope, filename: source.originalFilename,
                            timestamp: date.timeIntervalSince1970, width: recipe.metadata.pixelWidth,
                            height: recipe.metadata.pixelHeight, bytes: original.byteCount)
                        if candidate == .original {
                            await libraryEvent(.googleOriginalCandidate, requested)
                            return SafeFailure(.reconciliation, domain: .google, cause: .possibleOriginalMatch)
                        }
                    }
                }
            }
            if !cursor.complete, Date() >= catalogRetry {
                // The next job advances another bounded page slice; this file is not a lane gate.
                return SafeFailure(.reconciliation, domain: .google, cause: .googleIndexPending)
            }
            return nil
        } catch let gate as GoogleLibraryGate {
            throw gate.underlying
        } catch {
            if error is CancellationError { throw error }
            // Optional cache failure must not poison the proven exact-hash path.
            self.catalog = nil
            catalogRetry = Date().addingTimeInterval(3600)
            await libraryEvent(.googleLibraryUnavailable, requested, failure: ProviderSupport.safe(error, domain: .google))
            return nil
        }
    }
    private func readLibraryPage(_ cursor: GoogleLibraryCursor, destination: Destination) async throws -> GoogleLibraryPage {
        do {
            let subject = try await session.verifiedSubject()
            let page = try await session.libraryPage(cursor: cursor, subject: subject)
            try await verify(destination)
            return page
        } catch {
            let failure = ProviderSupport.safe(error, domain: .google)
            if failure.code == 403 {
                // The immediately preceding hash lookup succeeded. Prove the
                // linked identity again before degrading this optional endpoint.
                do { try await verify(destination) }
                catch { throw GoogleLibraryGate(underlying: error) }
                throw SafeFailure(.transfer, domain: .google, code: 403, cause: .formatRejected)
            }
            if ProviderSupport.blocksDestination(error, domain: .google) { throw GoogleLibraryGate(underlying: error) }
            throw error
        }
    }
    func allowOriginal(jobID: UUID, destination: Destination) async throws {
        try await verify(destination)
        if catalog == nil, let catalogURL { catalog = try GoogleRemoteIndex(url: catalogURL) }
        guard let catalog else { throw CoreError.invalidTransition }
        let tags = try await ledger.googleOverrideTags(jobID: jobID, destinationID: destination.id)
        _ = try await catalog.bind(destination.verifiedFingerprint)
        try await catalog.allowOriginal(scope: destination.verifiedFingerprint, tags: tags)
    }
    func libraryEvent(_ stage: DiagnosticStage, _ destination: Destination, failure: SafeFailure? = nil, items: Int? = nil, pages: Int? = nil) async {
        try? await ledger.appendEvent(.setupTrace, context: EventContext(origin: .google, destinationID: destination.id,
            diagnostic: DiagnosticDetail(stage: stage, status: failure == nil ? .succeeded : .failed,
                correlationID: UUID(), items: items, pages: pages)), decision: failure == nil ? .reconcile : .wait,
            severity: failure == nil ? .info : .warning, failure: failure)
    }
}
