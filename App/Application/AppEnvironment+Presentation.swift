import Foundation
import UIKit
@preconcurrency import Photos
import CloudifiedCore

extension AppEnvironment {
    var currentPhotosAccess: PhotosAccessState {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return .full
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .restricted
        }
    }
    func refreshPhotosAccess() {
        var next = dashboardState
        next.photosAccess = currentPhotosAccess
        next.permissionScopeDescription = next.photosAccess.description
        if next != dashboardState { dashboardState = next }
    }
    func recipe(_ asset: AssetIdentity) async throws -> SourceRecipe? {
        guard let data = try await ledger?.sourceRecipe(assetID: asset.id) else { return nil }
        return try SourceRecipe.decode(from: data)
    }
    /// Weight actual bytes across all components/parts, not one fraction for each
    /// part. Receipts and an active reader may overlap during finalization; count
    /// that resource once. No progress from elapsed time, estimates or thumbnail I/O.
    private func continuedWorkFraction(job: JobRecord, resource: ResourceRequirement?, bytes: Int64?, expected: Int64?) async throws -> Double {
        guard let ledger, job.state != .confirmed else { return 0 }
        let confirmed = Set(try await ledger.receipts(for: job.id).map(\.tag))
        func weight(_ value: ResourceRequirement) -> Double {
            value.originals.reduce(0) { $0 + Double(max(0, $1.byteCount)) }
        }
        let total = job.plan.resources.reduce(0) { $0 + weight($1) }
        guard total.isFinite, total > 0 else { return 0 }
        var done = job.plan.resources.filter { confirmed.contains($0.tag) }.reduce(0) { $0 + weight($1) }
        if let resource, !confirmed.contains(resource.tag), let bytes, let expected, expected > 0 {
            done += weight(resource) * min(1, Double(max(0, bytes)) / Double(expected))
        }
        return min(0.999999, max(0, done / total))
    }
    func performUIRefresh() async {
        // Automatic processing has no visible dashboard to refresh. Explicit
        // continued processing still needs measured system Progress updates.
        guard isForeground || continuation.state == .running else { return }
        let epoch = planningEpoch
        var next = dashboardState
        next.photosAccess = currentPhotosAccess
        next.permissionScopeDescription = next.photosAccess.description
        let fallbackEntries = fallback.snapshot().reversed().map {
            DiagnosticLogEntry(id: $0.id.uuidString, timestamp: $0.timestamp, origin: "System", severity: "error",
                stage: "Diagnostic persistence fallback (memory only)", message: explain($0.failure), safeErrorCode: $0.failure.description)
        }
        if fallbackEntries != logsState.fallbackEntries { logsState.fallbackEntries = fallbackEntries }
        guard let engine = backupEngine, let ledger else { return }
        do {
            let snapshot = try await engine.snapshot(), durable = snapshot.ledger
            let participating = durable.providers.filter(\.enabled)
            let continuedDestinations = Set(participating.compactMap(\.destinationID))
            var transfers: [CurrentTransferState] = []
            var continuedFractions: [Double] = []
            for provider in Provider.allCases {
                guard let activity = snapshot.active[provider] else { continue }
                let job = try await ledger.job(activity.jobID), source = try await recipe(job.asset)
                let resource = job.plan.resources.first { $0.id == activity.resourceID }
                if continuedDestinations.contains(job.destination.id) {
                    continuedFractions.append(try await continuedWorkFraction(job: job, resource: resource, bytes: activity.bytes, expected: activity.expectedBytes))
                }
                transfers.append(CurrentTransferState(id: provider.rawValue + ":" + job.id.uuidString, activity: activity.phase.rawValue.capitalized,
                    filename: resource.flatMap { r in source?.resources.first(where: { $0.sha256 == r.originals.first?.sha256 })?.originalFilename } ?? source?.resources.first?.originalFilename ?? "Media \(job.asset.id.uuidString.prefix(8)) (name unavailable)",
                    mediaType: job.asset.kind == .photo ? "Photo" : "Video", provider: provider.displayName,
                    bytesSent: activity.bytes ?? 0, totalBytes: activity.expectedBytes,
                    componentOrPart: resource.map(componentLabel), attemptNumber: activity.attempt > 0 ? activity.attempt : nil))
            }
            if let googleAdapter {
                for (job, resource, bytes, total) in try await googleAdapter.backgroundTransferSnapshot() {
                    guard snapshot.active[.google]?.jobID != job.id else { continue }
                    let source = try await recipe(job.asset)
                    let expected = total > 0 ? total : resource.originals.reduce(Int64(0)) { $0 + $1.byteCount }
                    if continuedDestinations.contains(job.destination.id) {
                        continuedFractions.append(try await continuedWorkFraction(job: job, resource: resource, bytes: bytes, expected: expected))
                    }
                    transfers.append(CurrentTransferState(id: "google:" + job.id.uuidString, activity: "System file upload", filename: source?.resources.first?.originalFilename ?? "Original media", mediaType: job.asset.kind == .photo ? "Photo" : "Video", provider: "Google Photos", bytesSent: bytes, totalBytes: expected, componentOrPart: componentLabel(resource), attemptNumber: job.attempts))
                }
            }
            // Native sends may still own inputs after a worker timeout. Merge on
            // job identity; never fabricate attempt 1 or label an acknowledgement Saved.
            let nativeWork = await telegramAdapter?.nativeTransferSnapshot() ?? []
            let channelCheck = await telegramAdapter?.channelCheckProgress().map { "Checking Telegram channel · \($0.formatted()) files read" }
            for native in nativeWork where native.activity != .uncertain {
                guard !transfers.contains(where: { $0.id == "telegram:" + native.jobID.uuidString }) else { continue }
                let job = try await ledger.job(native.jobID), source = try await recipe(job.asset)
                let resource = job.plan.resources.first { $0.tag == native.resourceTag }
                if continuedDestinations.contains(job.destination.id) {
                    continuedFractions.append(try await continuedWorkFraction(job: job, resource: resource, bytes: native.uploadedBytes, expected: native.expectedBytes))
                }
                let activity: String
                switch native.activity {
                case .uploading: activity = "Native upload in progress"
                case .awaitingAcknowledgement: activity = "Awaiting Telegram acknowledgement"
                case .waitingForConnection: activity = "Native send waiting for connection"
                case .uncertain: activity = "Awaiting verification"
                }
                transfers.append(CurrentTransferState(id: "telegram:" + native.jobID.uuidString, activity: activity,
                    filename: source?.resources.first?.originalFilename ?? "Original media (name unavailable)",
                    mediaType: job.asset.kind == .photo ? "Photo" : "Video", provider: "Telegram",
                    bytesSent: native.uploadedBytes, totalBytes: native.expectedBytes,
                    componentOrPart: resource.map(componentLabel), attemptNumber: job.attempts > 0 ? job.attempts : nil))
            }
            let outstanding = durable.providers.contains { $0.enabled && ($0.remaining ?? 0) > 0 }
            next.canPause = backupRequested && !pausedByUser && (backupExecutionTask != nil || !nativeWork.isEmpty || outstanding || retryTask != nil)
            next.canResume = !backupRequested && durable.scanned && (pausedByUser || resumeAfterExpiration)
            next.controlActivity = controlTransition ? (pausedByUser ? "Pausing…" : "Resuming…") : nil
            next.controlsAvailable = bootstrapComplete && backgroundExpirationTask == nil && commandProvider == nil && providerEnableTask == nil && !controlTransition
            next.currentTransfers = transfers
            next.accessibleLibraryTotal = durable.libraryTotal
            next.scanTimestamp = durable.scanStartedAt; next.savedToBothCount = durable.savedToBoth
            for provider in Provider.allCases {
                guard let value = durable.providers.first(where: { $0.provider == provider }) else { continue }
                let error = value.blockedReason ?? snapshot.laneFailures[provider] ?? providerErrors[provider]
                let activity: String
                if value.destinationID == nil {
                    activity = provider == .google && hasPendingGoogleCredential ? "Saved sign-in found" : "Not connected"
                }
                else if !value.enabled { activity = "Disabled — backlog retained" }
                else if let error {
                    activity = explain(error) + (value.resumeAt.flatMap { $0 > .now ? $0 : nil }
                        .map { " Resumes at \($0.formatted(date: .omitted, time: .shortened))." } ?? "")
                }
                else if provider == .telegram, let channelCheck { activity = channelCheck }
                else if !value.recoveryComplete { activity = "Checking existing remote content before uploads" }
                else if snapshot.paused { activity = "Paused" }
                else if let gate = snapshot.systemGate { activity = explain(SafeFailure(.connectivity, domain: .core, cause: gate)) }
                else if let active = transfers.first(where: { $0.provider == provider.displayName }) { activity = active.activity }
                else if planningProvider == provider { activity = "Preparing next original" }
                else if let date = value.resumeAt { activity = "Waiting until \(date.formatted())" }
                else { activity = backupRequested ? "Ready / checking remaining work" : "Idle" }
                var card = ProviderCardState(name: provider.displayName, isEnabled: value.enabled,
                    isConnected: value.destinationID != nil,
                    accountIdentifier: provider == .google ? settingsState.googleAccountEmail : settingsState.telegramAccountName,
                    channelIdentifier: provider == .telegram ? settingsState.telegramChannelName : nil,
                    currentActivity: activity, savedCount: value.confirmed, remainingCount: value.remaining,
                    totalCount: value.total, waitingCount: value.photos.flatMap { p in value.videos.map { p.waiting + $0.waiting } }, failedCount: value.photos.flatMap { p in value.videos.map { p.failed + $0.failed } },
                    lastConfirmedDate: value.lastConfirmedAt)
                card.retainedTransferCount = value.retainedTransfers
                card.protectedUnresolvedCount = value.protectedUnresolvedTransfers
                if value.destinationID != nil && value.enabled, let error {
                    if error.category == .authentication || [.loginRequired, .identityUnverified, .accountChanged].contains(error.cause) {
                        card.attention = .signIn
                    } else if provider == .google && error.category == .quota {
                        card.attention = .storage
                    }
                }
                if provider == .google { next.googleStatus = card } else { next.telegramStatus = card }
            }
            let g = durable.providers.first { $0.provider == .google }, t = durable.providers.first { $0.provider == .telegram }
            next.photosSection = mediaSection("Photos", total: durable.libraryPhotoTotal, kind: .photo, google: g?.photos, telegram: t?.photos, transfers: transfers)
            next.videosSection = mediaSection("Videos", total: durable.libraryVideoTotal, kind: .video, google: g?.videos, telegram: t?.videos, transfers: transfers)
            if isScanning { next.overallState = .scanning }
            else if snapshot.paused || pausedByUser { next.overallState = .paused }
            else if let cause = snapshot.systemGate { next.overallState = .waiting(reason: explain(SafeFailure(.connectivity, domain: .core, cause: cause))) }
            else if snapshot.active.values.contains(where: { $0.phase == .uploading }) || nativeWork.contains(where: { $0.activity == .uploading }) || transfers.contains(where: { $0.activity == "System file upload" }) { next.overallState = .uploading }
            else if snapshot.active.values.contains(where: { $0.phase == .finalizing }) { next.overallState = .finalizing }
            else if snapshot.active.values.contains(where: { $0.phase == .preparing }) { next.overallState = .preparing }
            else if snapshot.active.values.contains(where: { $0.phase == .checking }) { next.overallState = .checking }
            else if !transfers.isEmpty { next.overallState = .waiting(reason: "Awaiting upload confirmation") }
            else if let systemError { next.overallState = .needsAttention(reason: explain(systemError)) }
            else if planningProvider != nil { next.overallState = .preparing }
            else if !durable.scanned { next.overallState = .notScanned }
            else if durable.providers.contains(where: { $0.enabled && ($0.blockedReason != nil || !$0.recoveryComplete) }) { next.overallState = .checking }
            else if durable.providers.contains(where: { $0.enabled }) && durable.providers.filter({ $0.enabled }).allSatisfy({ $0.remaining == 0 }) { next.overallState = .complete }
            else { next.overallState = .idle }
            next.waitingOrErrorReason = systemError.map { explain($0) + " " + backgroundSummary } ?? backgroundSummary
            next.backgroundStatus = backgroundSummary
            next.backgroundRefreshOff = UIApplication.shared.backgroundRefreshStatus != .available || continuation.refreshDisabled
            next.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
            let lastRun = BackgroundRunJournal.last
            next.lastBackgroundRun = lastRun?.summary
            next.interruptedRunNotice = lastRun.flatMap { run in
                run.outcome == .interrupted && !run.acknowledged
                    ? "The last background backup stopped before it finished. Closing Cloudified from the app switcher ends background backup; iOS can also stop it."
                    : nil
            }
            let scan = isScanning ? scanProgress : nil
            continuation.update(confirmed: participating.compactMap(\.confirmed).reduce(0, +),
                total: durable.scanned && !isScanning ? participating.compactMap(\.total).reduce(0, +) : nil,
                activeFractions: continuedFractions,
                subtitle: scan.map { "Scanning library \($0.done.formatted()) of \($0.total.formatted())" } ?? channelCheck ?? next.overallState.title,
                scope: continuedDestinations, scan: scan)
            guard epoch == planningEpoch else { pendingRefresh = true; return }
            guard !Task.isCancelled, isForeground || continuation.state == .running else { return }
            var settings = settingsState
            if let g { settings.isGoogleEnabled = g.enabled; settings.isGoogleConnected = g.destinationID != nil }
            if let t { settings.isTelegramEnabled = t.enabled; settings.isTelegramConnected = t.destinationID != nil }
            settings.controlsAvailable = next.controlsAvailable
            settings.photosAccess = next.photosAccess
            settings.lastBackgroundRun = next.lastBackgroundRun
            settings.backupCanPause = next.canPause
            if settings != settingsState { settingsState = settings }
            let connected = durable.providers.filter { $0.destinationID != nil }
            let failures = connected.compactMap { p in p.photos.flatMap { a in p.videos.map { a.failed + $0.failed } } }
            let badge = !connected.isEmpty && failures.count == connected.count ? failures.reduce(0, +) : nil
            if activityFailureCount != badge { activityFailureCount = badge }
            activityPresentation.value = ActivityOverviewState(destinations: connected.map { p in
                ActivityOverviewState.Destination(id: p.provider.rawValue, name: p.provider.displayName,
                    saved: p.confirmed, total: p.total,
                    waiting: p.photos.flatMap { a in p.videos.map { a.waiting + $0.waiting } },
                    failed: p.photos.flatMap { a in p.videos.map { a.failed + $0.failed } }, enabled: p.enabled)
            })
            if next != dashboardState { dashboardState = next }
            // Keep diagnostic pages stable while read. User refresh/filter/paging
            // actions query them; upload progress does not reload a visible list.

        } catch {
            let safe = ProviderSupport.safe(error, domain: .sqlite)
            // Avoid a feedback loop through ledger observation or fallback events.
            next.overallState = .needsAttention(reason: explain(safe))
            next.waitingOrErrorReason = safe.description
            if next != dashboardState { dashboardState = next }
        }
    }
    func componentLabel(_ resource: ResourceRequirement) -> String {
        if let original = resource.originals.first, let index = original.partIndex, let count = original.partCount {
            return "\(resource.role.rawValue.capitalized) part \(index + 1) of \(count)"
        }
        return resource.role == .manifest ? "Archive manifest" : resource.role.rawValue.capitalized
    }
    func mediaSection(_ title: String, total: Int?, kind: MediaKind, google: MediaCounts?, telegram: MediaCounts?, transfers: [CurrentTransferState]) -> MediaSectionState {
        let active = transfers.filter { $0.mediaType == (kind == .photo ? "Photo" : "Video") }
        return MediaSectionState(title: title, subtitle: kind == .photo ? "Live Photo components remain one photo obligation" : "Original video bytes; no conversion",
            totalCount: total, googleSaved: google?.confirmed, googleRemaining: google?.remaining,
            googleFailed: google?.failed, telegramSaved: telegram?.confirmed, telegramRemaining: telegram?.remaining,
            telegramFailed: telegram?.failed, activeOperation: active.isEmpty ? nil : active.map { "\($0.provider): \($0.activity)" }.joined(separator: " · "),
            byteProgress: active.isEmpty ? nil : active.map { "\($0.provider): \($0.byteProgressText)" }.joined(separator: " · "))
    }
}
extension Provider { var displayName: String { self == .google ? "Google Photos" : "Telegram" } }
