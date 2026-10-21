import Foundation
import CloudifiedCore

/// App-owned actor isolating the pinned GPMCClient implementation and credential vault.
/// Handles session lifecycle, authenticated RPC dispatch, transport injection, and classified error diagnostics
/// while keeping account identity and transport ownership scoped to this session.
actor GooglePhotosClientSession {
    let profileID: String
    private let credentialStore: KeychainCredentialStore
    private let customTransport: (any FileUploadTransport)?
    private let networkPolicy: UploadRequestNetworkPolicy
    private let diagnosticSink: (@Sendable (EventOperation, EventContext, EventDecision, EventSeverity, SafeFailure?, TimeInterval?, Int64?, Int64?) async throws -> Void)?

    private var client: GPMCClient?
    private var isConfigured = false

    init(
        profileID: String,
        credentialStore: KeychainCredentialStore = KeychainCredentialStore(),
        transport: (any FileUploadTransport)? = nil,
        networkPolicy: UploadRequestNetworkPolicy = UploadRequestNetworkPolicy(),
        diagnosticSink: (@Sendable (EventOperation, EventContext, EventDecision, EventSeverity, SafeFailure?, TimeInterval?, Int64?, Int64?) async throws -> Void)? = nil
    ) throws {
        try KeychainCredentialStore.validateProfileID(profileID)
        self.profileID = profileID
        self.credentialStore = credentialStore
        self.customTransport = transport
        self.networkPolicy = networkPolicy
        self.diagnosticSink = diagnosticSink
    }

    /// Whether a credential has been configured and loaded for this profile.
    var hasConfiguredCredential: Bool {
        isConfigured
    }

    /// Connects using an existing stored credential from Keychain.
    func loadSavedSession() async throws {
        let cred = try credentialStore.loadGoogleCredential(forProfile: profileID)
        let gpmc = try GPMCClient(authData: cred.authData, networkPolicy: networkPolicy, fileUploadTransport: customTransport)
        self.client = gpmc
        self.isConfigured = true

        try await emitDiagnostic(.appStart, decision: .proceed, severity: .info)
    }

    /// Connects by exchanging a freshly acquired OAuth authorization token.
    func connect(oauthToken: String) async throws -> StoredGoogleCredential {
        let policy = networkPolicy
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        let owned = URLSession(configuration: config)
        defer { owned.invalidateAndCancel() }
        let sink = diagnosticSink
        let result = try await GoogleTokenExchange.run(oauthToken: oauthToken, session: owned, requestPolicy: { request in
            policy.apply(to: &request)
        }, onDiagnostic: { detail, failure, duration in
            try? await sink?(.setupTrace, EventContext(origin: .google, diagnostic: detail),
                failure == nil ? .proceed : .wait, failure == nil ? .info : .error, failure, duration, nil, nil)
        })
        let cred = StoredGoogleCredential(
            androidId: result.androidId,
            email: result.email,
            masterToken: result.masterToken,
            authData: result.authData,
            connectedAt: Date()
        )
        try credentialStore.saveGoogleCredential(cred, forProfile: profileID)

        let gpmc = try GPMCClient(authData: cred.authData, freshExchange: result, networkPolicy: networkPolicy, fileUploadTransport: customTransport)
        self.client = gpmc
        self.isConfigured = true

        try await emitDiagnostic(.enabledChanged, decision: .proceed, severity: .info)
        return cred
    }

    /// Clears active client state and removes stored credentials from Keychain.
    func disconnect() async throws {
        client = nil
        isConfigured = false
        try credentialStore.deleteGoogleCredential(forProfile: profileID)

        try await emitDiagnostic(.finalization, decision: .proceed, severity: .info)
    }

    private func requireClient() throws -> GPMCClient {
        guard let client else {
            throw SafeFailure(.authentication, domain: .google, cause: .loginRequired)
        }
        return client
    }

    private func traced<T: Sendable>(_ stage: DiagnosticStage, work: () async throws -> T) async throws -> T {
        let id = UUID(), started = ProcessInfo.processInfo.systemUptime
        func context(_ status: DiagnosticStatus, reason: DiagnosticGoogleError? = nil, actualStage: DiagnosticStage? = nil) -> EventContext {
            EventContext(origin: .google, diagnostic: DiagnosticDetail(stage: actualStage ?? stage, status: status, correlationID: id, googleError: reason))
        }
        try? await diagnosticSink?(.setupTrace, context(.started), .proceed, .info, nil, nil, nil, nil)
        do {
            let value = try await work()
            try? await diagnosticSink?(.setupTrace, context(.succeeded), .proceed, .info, nil,
                ProcessInfo.processInfo.systemUptime - started, nil, nil)
            return value
        } catch {
            let safe = (error as? GPMCError).map(Self.classify) ?? ProviderSupport.safe(error, domain: .google)
            try? await diagnosticSink?(.setupTrace, context(.failed, reason: (error as? GPMCError)?.googleReason, actualStage: (error as? GPMCError)?.diagnosticStage), .wait, .error, safe,
                ProcessInfo.processInfo.systemUptime - started, nil, nil)
            if let error = error as? GPMCError { throw SafeProviderFailure(failure: safe, retryAfter: error.retryAfter) }
            throw error
        }
    }
    func authenticate() async throws {
        try await traced(.googleAuthenticate) { try await self.requireClient().authenticate() }
    }
    func verifiedSubject() async throws -> String {
        let sink = diagnosticSink
        return try await traced(.googleIdentity) {
            try await self.requireClient().verifiedSubject(onDiagnostic: { detail, failure, duration in
                try? await sink?(.setupTrace, EventContext(origin: .google, diagnostic: detail),
                    failure == nil ? .proceed : .wait, failure == nil ? .info : .error, failure, duration, nil, nil)
            })
        }
    }
    var usesBackgroundTransfers: Bool {
        get async { guard let client else { return false }; return await client.usesBackgroundFileTransfers }
    }
    func validateReadAccess() async throws {
        try await traced(.googleReadAccess) { try await self.requireClient().validateReadAccess() }
    }

    /// Checks remote presence by SHA-1 hash without uploading.
    func checkPresence(sha1: Data, asLivePhotoMotion: Bool = false) async throws -> String? {
        let client = try requireClient()
        do {
            return try await traced(.googleDuplicateCheck) {
                try await client.remoteMediaKey(sha1: sha1, asLivePhotoMotion: asLivePhotoMotion)
            }
        } catch let err as GPMCError {
            let classified = Self.classify(err)
            try await emitDiagnostic(.failure, decision: .wait, severity: .error, failure: classified)
            throw SafeProviderFailure(failure: classified, retryAfter: err.retryAfter)
        }
    }

    func prepareVerifiedUpload(file: URL, filename: String, modified: Date?, hash: Data, byteCount: Int64,
                               stillHash: Data?, phase: @escaping @Sendable (UploadPhase) -> Void) async throws -> UploadPreparation {
        do { return try await traced(.googleUploadPreparation) {
            try await self.requireClient().prepareVerifiedUpload(file: file, filename: filename, modified: modified,
                     hash: hash, byteCount: byteCount, stillHash: stillHash, phase: phase)
        } }
        catch let error as GPMCError { throw SafeProviderFailure(failure: Self.classify(error), retryAfter: error.retryAfter) }
    }

    /// Prepares an upload session for a standard photo or video original.
    func prepareUpload(
        file: URL,
        filename: String,
        modified: Date? = nil,
        phase: @escaping @Sendable (UploadPhase) -> Void
    ) async throws -> UploadPreparation {
        let client = try requireClient()
        do {
            return try await client.prepareUpload(file: file, filename: filename, modified: modified, phase: phase)
        } catch let err as GPMCError {
            let classified = Self.classify(err)
            try await emitDiagnostic(.failure, decision: .wait, severity: .error, failure: classified)
            throw SafeProviderFailure(failure: classified, retryAfter: err.retryAfter)
        }
    }

    /// Prepares an upload session for the motion video of a Live Photo.
    func prepareMotionUpload(
        file: URL,
        filename: String,
        modified: Date? = nil,
        stillHash: Data,
        phase: @escaping @Sendable (UploadPhase) -> Void
    ) async throws -> UploadPreparation {
        let client = try requireClient()
        do {
            return try await client.prepareMotionUpload(
                file: file,
                filename: filename,
                modified: modified,
                stillHash: stillHash,
                phase: phase
            )
        } catch let err as GPMCError {
            let classified = Self.classify(err)
            try await emitDiagnostic(.failure, decision: .wait, severity: .error, failure: classified)
            throw SafeProviderFailure(failure: classified, retryAfter: err.retryAfter)
        }
    }

    /// Transfers file bytes using the configured transport.
    func transfer(
        prepared: PreparedUpload,
        file: URL,
        transferID: UUID,
        foreground: Bool = false,
        phase: @escaping @Sendable (UploadPhase) -> Void
    ) async throws -> PreparedUpload {
        let client = try requireClient()
        do {
            return try await traced(.googleFileTransfer) {
                try await client.transfer(prepared, file: file, transferID: transferID, foreground: foreground, phase: phase)
            }
        } catch let err as GPMCError {
            let classified = Self.classify(err)
            try await emitDiagnostic(.failure, decision: .wait, severity: .error, failure: classified)
            throw SafeProviderFailure(failure: classified, retryAfter: err.retryAfter)
        }
    }

    func submit(prepared: PreparedUpload, file: URL, transferID: UUID) async throws {
        try await traced(.googleTransferQueued) {
            try await self.requireClient().submit(prepared, file: file, transferID: transferID)
        }
    }
    func recoveredTransfer(_ prepared: PreparedUpload, result: FileUploadResult) async throws -> PreparedUpload {
        do { return try await requireClient().receivedTransfer(prepared, result: result) }
        catch let error as GPMCError { throw SafeProviderFailure(failure: Self.classify(error), retryAfter: error.retryAfter) }
    }

    /// Commits the upload receipt to Google Photos.
    func commit(
        prepared: PreparedUpload,
        useQuota: Bool,
        saver: Bool,
        pairedStillHash: Data? = nil,
        phase: @escaping @Sendable (UploadPhase) -> Void
    ) async throws -> UploadOutcome {
        let client = try requireClient()
        do {
            return try await traced(.googleCommit) {
                try await client.commit(prepared, useQuota: useQuota, saver: saver, pairedStillHash: pairedStillHash, phase: phase)
            }
        } catch let err as GPMCError {
            let classified = Self.classify(err)
            try await emitDiagnostic(.failure, decision: .wait, severity: .error, failure: classified)
            throw SafeProviderFailure(failure: classified, retryAfter: err.retryAfter)
        }
    }

    /// Cancels a running background transfer.
    func cancelTransfer(_ transferID: UUID) async {
        guard let client else { return }
        await client.cancelTransfer(transferID)
    }

    /// Forgets a completed transfer token association.
    func forgetTransfer(_ transferID: UUID) async {
        guard let client else { return }
        await client.forgetTransfer(transferID)
    }

    private func emitDiagnostic(
        _ operation: EventOperation,
        decision: EventDecision,
        severity: EventSeverity,
        failure: SafeFailure? = nil
    ) async throws {
        guard let diagnosticSink else { return }
        let context = EventContext(origin: .google)
        try await diagnosticSink(operation, context, decision, severity, failure, nil, nil, nil)
    }

    // MARK: - Error Classification

    /// Maps GPMC protocol errors to Core classified SafeFailure values.
    static func classify(_ error: GPMCError) -> SafeFailure {
        switch error.kind {
        case .identityUnavailable:
            return error.transportFailure ?? SafeFailure(.authentication, domain: .google, cause: .identityUnverified)
        case .credentialRejected:
            return error.transportFailure ?? SafeFailure(.authentication, domain: .google, cause: .loginRequired)
        case .tokenBound:
            return SafeFailure(.authentication, domain: .google, cause: .loginRequired)
        case .storageFull:
            return SafeFailure(.quota, domain: .google, cause: .quotaExceeded)
        case .transport:
            return error.transportFailure ?? SafeFailure(.connectivity, domain: .google, cause: .networkRequestFailed)
        case .invalidUploadReceipt:
            return SafeFailure(.transfer, domain: .google, cause: .providerRejected)
        case .pairedPhotoMissing:
            return SafeFailure(.transfer, domain: .google, cause: .unknown)
        case .server(let code):
            if code == 429 {
                return SafeFailure(.rateLimit, domain: .google, code: code, cause: .serverRateLimit)
            }
            if code == 408 {
                return SafeFailure(.timeout, domain: .google, code: code, cause: .deadlineExceeded)
            }
            if error.diagnosticStage == .googleIdentity || error.diagnosticStage == .googleTokenInfo {
                return SafeFailure(.authentication, domain: .google, code: code, cause: .identityUnverified)
            }
            return SafeFailure(.transfer, domain: .google, code: code, cause: .providerRejected)
        case .malformed:
            return SafeFailure(.transfer, domain: .google, cause: .formatRejected)
        }
    }
}
