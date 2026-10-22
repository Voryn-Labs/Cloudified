import Foundation
import CloudifiedCore

extension AppEnvironment {
    public func reloadFailures() {
        failureQueryGeneration += 1; failureCursor = nil; sourceFailureCursor = nil
        failurePageHistory.removeAll(); notUploadedState.hasNewer = false
        nextFailureCursor = nil; nextSourceFailureCursor = nil
        notUploadedState.hasOlder = false
        loadFailurePage(generation: failureQueryGeneration, older: false)
    }
    public func olderFailures() {
        guard !notUploadedState.isLoading, notUploadedState.hasOlder else { return }
        failurePageHistory.append((failureCursor, sourceFailureCursor))
        if failurePageHistory.count > 20 { failurePageHistory.removeFirst() }
        failureCursor = nextFailureCursor; sourceFailureCursor = nextSourceFailureCursor
        loadFailurePage(generation: failureQueryGeneration, older: true)
    }
    public func newerFailures() {
        guard !notUploadedState.isLoading, let previous = failurePageHistory.popLast() else { return }
        failureCursor = previous.0; sourceFailureCursor = previous.1
        loadFailurePage(generation: failureQueryGeneration, older: previous.0 != nil || previous.1 != nil)
    }
    func loadFailurePage(generation: Int, older: Bool) {
        let filter = notUploadedState
        let provider: Provider? = filter.destinationFilter == .google ? .google : (filter.destinationFilter == .telegram ? .telegram : nil)
        let kind: MediaKind? = filter.mediaTypeFilter == .photos ? .photo : (filter.mediaTypeFilter == .videos ? .video : nil)
        let states: [JobState]? = filter.statusFilter == .failed ? [.failed] : (filter.statusFilter == .waiting ? [.waiting, .reconciling] : (filter.statusFilter == .pending ? [.delayed] : nil))
        let failureBefore = failureCursor, sourceBefore = sourceFailureCursor
        notUploadedState.isLoading = true; notUploadedState.pageError = nil
        failurePageTask?.cancel()
        failurePageTask = Task { [weak self] in
            guard let self, let ledger = self.ledger else { self?.notUploadedState.isLoading = false; return }
            do {
                let failures = !older || failureBefore != nil ? try await ledger.failurePage(beforeCursor: failureBefore, provider: provider, kind: kind, limit: 50, states: states) : []
                let sources = filter.statusFilter != .pending && (!older || sourceBefore != nil) ? try await ledger.sourceFailurePage(beforeCursor: sourceBefore, provider: provider, kind: kind, limit: 50,
                    permanent: filter.statusFilter == .failed ? true : (filter.statusFilter == .waiting ? false : nil)) : []
                var items: [NotUploadedItem] = []
                for row in failures {
                    try Task.checkCancellation()
                    let source = try row.recipeData.map { try SourceRecipe.decode(from: $0) }
                    let retained = row.retained
                    let recover = retained || row.job.state == .reconciling || FailureExplanation.requiresReconciliation(row.failure)
                    items.append(NotUploadedItem(id: row.asset.id.uuidString + row.job.destination.id.uuidString,
                        destinationID: row.job.destination.id,
                        canRetry: !recover && (row.job.state == .failed || row.failure?.cause == .pairingUnverified || row.failure?.cause == .possibleOriginalMatch), needsRecovery: recover,
                        jobID: row.job.id, localIdentifier: row.asset.localIdentifier,
                        filename: source?.resources.first?.originalFilename ?? "Original media (name unavailable)",
                        captureDate: source?.metadata.creationDate, mediaType: row.asset.kind == .photo ? "Photo" : "Video",
                        durationSeconds: source?.metadata.durationSeconds, provider: row.job.destination.provider.displayName,
                        status: row.job.state == .failed ? "Failed" : (row.job.state == .delayed ? "Pending retry" : "Waiting"),
                        attemptCount: row.job.attempts, stage: row.job.state.rawValue,
                        errorCategory: row.failure?.category.rawValue ?? "Pending verification", technicalCode: row.failure?.description,
                        plainLanguageReason: row.failure.map(self.explain) ?? "Waiting for a verified result.", suggestedRemedy: FailureExplanation.remedy(row.failure),
                        confirmedComponents: ["\(row.confirmedResources) of \(row.requiredResources) obligations confirmed"],
                        missingObligations: ["\(row.requiredResources - row.confirmedResources) obligations remain"], nextRetryDate: row.job.retryAt))
                }
                for row in sources {
                    try Task.checkCancellation()
                    let source = try row.recipeData.map { try SourceRecipe.decode(from: $0) }
                    items.append(NotUploadedItem(id: row.asset.id.uuidString + row.destination.id.uuidString,
                        destinationID: row.destination.id, sourceAsset: row.asset, canRetry: true, localIdentifier: row.asset.localIdentifier,
                        filename: source?.resources.first?.originalFilename ?? "Original media (name unavailable)", captureDate: source?.metadata.creationDate,
                        mediaType: row.asset.kind == .photo ? "Photo" : "Video", durationSeconds: source?.metadata.durationSeconds,
                        provider: row.destination.provider.displayName, status: row.permanent ? "Failed source preparation" : "Waiting for source",
                        stage: "Source preparation (upload not started)", errorCategory: row.error.category.rawValue, technicalCode: row.error.description,
                        plainLanguageReason: self.explain(row.error), suggestedRemedy: FailureExplanation.remedy(row.error)))
                }
                guard generation == self.failureQueryGeneration else { return }
                self.nextFailureCursor = failures.count == 50 ? failures.last?.cursor : nil
                self.nextSourceFailureCursor = sources.count == 50 ? sources.last?.cursor : nil
                // A page replaces the visible window. No unbounded append/cache.
                var seen: Set<String> = []
                self.notUploadedState.items = items.filter { seen.insert($0.id).inserted }
                self.notUploadedState.hasOlder = self.nextFailureCursor != nil || self.nextSourceFailureCursor != nil
                self.notUploadedState.isLoading = false
                self.notUploadedState.hasLoaded = true
                self.notUploadedState.hasNewer = !self.failurePageHistory.isEmpty
            } catch {
                guard generation == self.failureQueryGeneration else { return }
                self.notUploadedState.isLoading = false
                self.notUploadedState.pageError = self.explain(ProviderSupport.safe(error, domain: .sqlite))
            }
        }
    }
    public func reloadLogs() {
        logQueryGeneration += 1; logCursor = nil; nextLogCursor = nil
        logPageHistory.removeAll(); logsState.hasNewer = false
        logsState.hasOlder = false
        loadLogPage(generation: logQueryGeneration)
    }
    public func olderLogs() {
        guard !logsState.isLoading, logsState.hasOlder else { return }
        logPageHistory.append(logCursor)
        if logPageHistory.count > 20 { logPageHistory.removeFirst() }
        logCursor = nextLogCursor; loadLogPage(generation: logQueryGeneration)
    }
    public func newerLogs() {
        guard !logsState.isLoading, let previous = logPageHistory.popLast() else { return }
        logCursor = previous; loadLogPage(generation: logQueryGeneration)
    }
    func loadLogPage(generation: Int) {
        let filter = logsState, before = logCursor
        let origins: [EventOrigin]? = filter.originFilter == .google ? [.google] : (filter.originFilter == .telegram ? [.telegram] : (filter.originFilter == .system ? [.system, .source] : nil))
        let severity: EventSeverity? = filter.severityFilter == .info ? .info : (filter.severityFilter == .warning ? .warning : (filter.severityFilter == .error ? .error : nil))
        logsState.isLoading = true; logsState.pageError = nil
        logPageTask?.cancel()
        logPageTask = Task { [weak self] in
            guard let self, let ledger = self.ledger else { self?.logsState.isLoading = false; return }
            do {
                let page = try await ledger.logPage(beforeSequence: before, severity: severity, runID: filter.selectedRunID, limit: 100, origins: origins)
                guard generation == self.logQueryGeneration else { return }
                self.logsState.entries = page.events.map {
                    DiagnosticLogEntry(id: String($0.sequence), timestamp: $0.timestamp,
                        origin: $0.context.origin == .google ? "Google Photos" : $0.context.origin.rawValue.capitalized,
                        severity: $0.severity.rawValue, stage: $0.context.diagnostic?.stage.rawValue ?? $0.operation.rawValue, attemptNumber: $0.context.attempt,
                        message: self.diagnosticMessage($0), safeErrorCode: $0.failure?.description)
                }
                self.nextLogCursor = page.events.count == 100 ? page.nextBeforeSequence : nil
                self.logsState.hasOlder = self.nextLogCursor != nil
                self.logsState.prunedEventCount = page.prunedEventCount; self.logsState.isLoading = false
                self.logsState.hasLoaded = true
                self.logsState.hasNewer = !self.logPageHistory.isEmpty
            } catch {
                guard generation == self.logQueryGeneration else { return }
                self.logsState.isLoading = false; self.logsState.pageError = self.explain(ProviderSupport.safe(error, domain: .sqlite))
            }
        }
    }
    public func loadRuns(older: Bool = false) {
        if !older { runCursor = nil }
        let before = runCursor
        runPageTask?.cancel()
        runPageTask = Task { [weak self] in
            guard let self, let ledger = self.ledger else { return }
            do {
                let page = try await ledger.runPage(before: before, limit: 20)
                try Task.checkCancellation()
                self.logsState.runs = page.map { LogRunChoice(id: $0.id, title: "\($0.started.formatted()) · \($0.outcome ?? "unfinished") · \($0.revision.prefix(8))") }
                self.runCursor = page.last?.started; self.logsState.hasOlderRuns = page.count == 20
            } catch { self.logsState.pageError = self.explain(ProviderSupport.safe(error, domain: .sqlite)) }
        }
    }
    public func attemptHistory(_ item: NotUploadedItem, before: Int64? = nil) async throws -> [AttemptHistoryRow] {
        guard let id = item.jobID, let ledger else { return [] }
        return try await ledger.attemptHistoryPage(jobID: id, beforeCursor: before, limit: 25)
    }
    public func exportRedactedLogs() async throws -> URL {
        guard let ledger, let exportStore else { throw CoreError.recoveryRequired }
        let url = try await exportStore.export(ledger: ledger)
        do { try Task.checkCancellation(); return url }
        catch { try await exportStore.release(url); throw error }
    }
    public func releaseExport(_ url: URL) {
        Task { [weak self] in
            do { try await self?.exportStore?.release(url) } catch { await self?.report(error, provider: nil) }
        }
    }
}
