import Foundation
import CloudifiedCore
import UIKit

extension AppEnvironment {
    func trace(_ stage: DiagnosticStage, _ status: DiagnosticStatus, provider: Provider? = nil,
               id: UUID = UUID(), started: TimeInterval? = nil, failure: SafeFailure? = nil, backgroundEvent: DiagnosticBackgroundEvent? = nil) async {
        await recordTrace(makeDiagnosticDetail(stage, status, id: id, backgroundEvent: backgroundEvent), provider: provider, failure: failure, started: started)
    }
    func makeDiagnosticDetail(_ stage: DiagnosticStage, _ status: DiagnosticStatus, id: UUID,
                              backgroundEvent: DiagnosticBackgroundEvent? = nil) -> DiagnosticDetail {
        DiagnosticDetail(stage: stage, status: status, correlationID: id,
            available: network?.available, wifi: network?.wifi,
            expensive: network?.expensive, constrained: network?.constrained, backgroundEvent: backgroundEvent,
            foreground: isForeground, backgroundExecutionAllowed: backgroundExecutionAllowed,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, backupIntent: backupIntent, policyCause: policyGate)
    }
    func recordTrace(_ detail: DiagnosticDetail, provider: Provider? = nil, failure: SafeFailure? = nil, started: TimeInterval? = nil) async {
        do {
            try await diagnosticSink(.setupTrace,
                EventContext(origin: provider?.origin ?? .system, diagnostic: detail),
                failure == nil ? .proceed : .wait, failure == nil ? .info : .error, failure,
                started.map { max(0, ProcessInfo.processInfo.systemUptime - $0) }, nil, nil)
        } catch { /* Existing sink already records safe persistence failure. */ }
    }
    var connectionNetworkFailure: SafeFailure? {
        if network?.available != true { return SafeFailure(.connectivity, domain: .core, cause: .offline) }
        if network?.constrained == true { return SafeFailure(.connectivity, domain: .core, cause: .lowDataMode) }
        if !allowedNetwork { return SafeFailure(.connectivity, domain: .core, cause: .wifiRequired) }
        return nil
    }
    func diagnosticMessage(_ event: DiagnosticEvent) -> String {
        var text = event.failure.map(explain) ?? event.decision.rawValue
        if let failure = event.failure { text += "\nSafe code: \(failure.description)" }
        if let detail = event.context.diagnostic {
            text += "\nStage: \(detail.stage.rawValue) · \(detail.status.rawValue)"
            text += "\nOperation: \(detail.correlationID.uuidString)"
            if let method = detail.nativeMethod { text += "\nNative request: \(method.rawValue)" }
            if let reason = detail.nativeError { text += "\nNative rejection: \(reason.rawValue)" }
            if let state = detail.authState { text += "\nAuthorization: \(state.rawValue)" }
            if let reason = detail.googleError { text += "\nGoogle response classification: \(reason.rawValue)" }
            if let value = detail.backgroundEvent { text += "\nBackground event: \(value.rawValue)" }
            if let value = detail.reportRejection { text += "\nReport-host rejection: \(value.rawValue)" }
            if let value = detail.requestBytes { text += "\nRequest body bytes: \(value)" }
            if let value = detail.foreground { text += "\nForeground: \(value)" }
            if let value = detail.backgroundExecutionAllowed { text += "\nBackground execution granted: \(value)" }
            if let value = detail.backupIntent { text += "\nBackup invocation: \(value.rawValue)" }
            if let value = detail.policyCause { text += "\nExecution policy: \(value.rawValue)" }
            if let value = detail.lowPowerMode { text += "\nLow Power Mode: \(value)" }
            if let value = detail.items { text += "\nItems: \(value)" }
            if let value = detail.pages { text += "\nPages: \(value)" }
            if let value = detail.reused { text += "\nReused verified scan cursor: \(value)" }
            if let code = detail.httpStatus { text += "\nHTTP status: \(code)" }
            if let bytes = detail.responseBytes { text += "\nResponse bytes: \(bytes)" }
            if let value = detail.available { text += "\nNetwork path: \(value ? "available" : "unavailable")" }
            if let value = detail.wifi { text += " · Wi-Fi: \(value)" }
            if let value = detail.expensive { text += " · Expensive: \(value)" }
            if let value = detail.constrained { text += " · Low Data: \(value)" }
        }
        if let duration = event.duration { text += "\nElapsed seconds: \(String(format: "%.3f", duration))" }
        return text
    }
    public var canRetryGoogleVerification: Bool { hasPendingGoogleCredential && !settingsState.isGoogleConnected }
    public func retryGoogleVerification() async throws { try await connectGoogle(oauthToken: nil) }
    public func uploadDiagnosticReport() async throws -> URL {
        let id = UUID(), started = ProcessInfo.processInfo.systemUptime
        await trace(.diagnosticUpload, .started, id: id)
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var metadata = DiagnosticReportMetadata(
            version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unavailable",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unavailable",
            revision: Bundle.main.object(forInfoDictionaryKey: "CloudifiedRevision") as? String ?? "unavailable",
            osMajor: os.majorVersion, osMinor: os.minorVersion, osPatch: os.patchVersion,
            providerClientsAvailable: googleSession != nil && tdlibClient != nil,
            googleCredentialAvailable: hasPendingGoogleCredential,
            network: makeDiagnosticDetail(.networkPolicy, .changed, id: id))
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        let ownPrefix = Bundle.main.bundleIdentifier.map { $0 + ".backup." }
        let prefixes = BackupContinuation.identifierPrefixes(bundleID: Bundle.main.bundleIdentifier, permitted: permitted)
        let queued = continuation.state == .requested ? continuation.requestedAt.map {
            Int(min(604_800, max(0, ProcessInfo.processInfo.systemUptime - $0)))
        } : nil
        metadata.backgroundConfiguration = DiagnosticBackgroundConfiguration(continuationState: continuation.state.rawValue,
            queuedSeconds: queued, permittedIdentifierCount: permitted.count,
            matchesSignedBundle: ownPrefix.map { prefixes.contains($0) } ?? false,
            backgroundRefreshAvailable: UIApplication.shared.backgroundRefreshStatus == .available)
        do {
            let url = try await reportUploader.upload(ledger: ledger, metadata: metadata,
                fallback: fallback.snapshot().map { DiagnosticReportFallback(timestamp: $0.timestamp, failure: $0.failure) },
                responseObserved: { [diagnosticSink] status, bytes, requestBytes, rejection in
                    try? await diagnosticSink(.diagnosticUpload,
                        EventContext(origin: .system, diagnostic: DiagnosticDetail(stage: .diagnosticUpload,
                            status: .changed, correlationID: id, httpStatus: status, responseBytes: bytes,
                            reportRejection: rejection, requestBytes: requestBytes)),
                        .proceed, .info, nil, nil, nil, nil)
                })
            await trace(.diagnosticUpload, .succeeded, id: id, started: started)
            return url
        } catch {
            await trace(.diagnosticUpload, .failed, id: id, started: started, failure: ProviderSupport.safe(error, domain: .urlSession))
            throw error
        }
    }
}
