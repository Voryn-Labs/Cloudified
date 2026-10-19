import Foundation

public enum EventOrigin: String, Codable, Sendable { case google, telegram, source, system }
public enum EventSeverity: String, Codable, Sendable { case info, warning, error }
public enum EventOperation: String, Codable, Sendable {
    case appStart, scanStart, scanPage, scanComplete, batchStart, batchEnd, pause, resume
    case mappingChanged, enabledChanged, recovery, remoteCheck, preparation, export, hashing
    case laneStart, laneEnd, attemptStart, transferStart, progress, finalization, confirmation
    case failure, retryScheduled, exhausted, explicitRetry, network, backgroundExpiration
    case leaseAcquire, leaseRelease, cleanup, databaseFailure, diagnosticsPruned
    case setupTrace, nativeRequest, diagnosticUpload
}
public enum EventDecision: String, Codable, Sendable { case proceed, retry, wait, skip, reconcile, confirmed }
public enum FailureCategory: String, Codable, Sendable {
    case sourceUnavailable, accessDenied, diskFull, unsupportedOriginal, connectivity, timeout
    case rateLimit, authentication, quota, transfer, finalization, reconciliation, invariant
}
public enum ErrorDomain: String, Codable, Sendable { case photos, fileSystem, urlSession, google, tdlib, sqlite, core }
public enum KnownCause: String, Codable, Sendable {
    case unknown, permissionDenied, sourceMissing, insufficientSpace, formatRejected, offline
    case deadlineExceeded, serverRateLimit, loginRequired, quotaExceeded, providerRejected
    case incompleteHistory, outcomeUnknown, interrupted, disabled, paused, contentChanged
    case persistenceFailed, invalidContract, identityUnverified, pairingUnverified, pendingSendUnmatched
    case privateChannelRequired, accountChanged
    case lowDataMode, wifiRequired, thermalPressure, backgroundRestricted, backgroundExpired, lowPowerMode
    case storageUnavailable, storagePathConflict
    case setupUnavailable, initializationFailed, verificationFailed, networkRequestFailed
    case phoneNumberInvalid, phoneNumberBanned, applicationCredentialsRejected, authenticationRejected
    case nativeResponseInvalid, nativeResponseLimit, databaseKeyUnavailable
}

public enum DiagnosticStage: String, Codable, Sendable {
    case startup, providerChange, googleConnect, googleMasterToken, googlePhotosToken
    case googleAuthenticate, googleIdentity, googleTokenInfo, googleReadAccess, googleMapping, googleRecovery
    case telegramStart, telegramStorage, telegramNativeCreate, telegramAuthorization
    case telegramNetwork, telegramParameters, telegramAuthState, nativeRequest, networkPolicy
    case diagnosticExport, diagnosticUpload, backgroundContinuation, automaticBackground
    case googleTransferActive, googleTransferCompleted, googleTransferAbsent, googleTransferFailed
    case googleDuplicateCheck, googleUploadPreparation, googleFileTransfer, googleCommit
    case telegramCensus, telegramRecovery, telegramProtocol, telegramLocalReset, originalIntegrityCheck, startupInventory
}
public enum DiagnosticStatus: String, Codable, Sendable { case started, succeeded, failed, changed }
public enum DiagnosticNativeMethod: String, Codable, Sendable {
    case getAuthorizationState, setNetworkType, setTdlibParameters, setAuthenticationPhoneNumber
    case checkAuthenticationCode, checkAuthenticationPassword, setAuthenticationEmailAddress
    case checkAuthenticationEmailCode, getMe, getChat, getChats, loadChats, searchChatsOnServer
    case getSupergroup, getSupergroupFullInfo, getChatHistory, searchChatMessages, getMessage, getFile, downloadFile, deleteFile, sendMessage, close, logOut, other
}
public enum DiagnosticAuthState: String, Codable, Sendable {
    case uninitialized, waitTdlibParameters, waitPhoneNumber, waitCode, waitPassword
    case waitEmailAddress, waitEmailCode, waitOtherDeviceConfirmation, waitRegistration
    case waitPremiumPurchase, ready, loggingOut, closing, closed, uncertain
}
public enum DiagnosticNativeError: String, Codable, Sendable {
    case responseByteLimit, responseNodeLimit, responseDepthLimit, malformedNativeResponse
    case phoneNumberInvalid = "PHONE_NUMBER_INVALID"
    case phoneNumberBanned = "PHONE_NUMBER_BANNED"
    case apiIdInvalid = "API_ID_INVALID"
    case apiIdPublishedFlood = "API_ID_PUBLISHED_FLOOD"
    case phoneNumberFlood = "PHONE_NUMBER_FLOOD"
    case phonePasswordFlood = "PHONE_PASSWORD_FLOOD"
    case phoneCodeInvalid = "PHONE_CODE_INVALID"
    case phoneCodeExpired = "PHONE_CODE_EXPIRED"
    case passwordHashInvalid = "PASSWORD_HASH_INVALID"
    case updateAppToLogin = "UPDATE_APP_TO_LOGIN"
    case authRestart = "AUTH_RESTART"
    case other
}
public enum DiagnosticGoogleError: String, Codable, Sendable {
    case badAuthentication = "BadAuthentication"
    case needsBrowser = "NeedsBrowser"
    case deviceManagement = "DeviceManagementRequiredOrSyncDisabled"
    case tokenBound, missingToken, other
    case invalidRequest = "invalid_request"
    case invalidToken = "invalid_token"
    case insufficientScope = "insufficient_scope"
    case invalidGrant = "invalid_grant"
    case accessDenied = "access_denied"
    case unsupportedTokenType = "unsupported_token_type"
    case invalidArgument = "INVALID_ARGUMENT"
    case permissionDenied = "PERMISSION_DENIED"
    case unauthenticated = "UNAUTHENTICATED"
}
public enum DiagnosticBackgroundEvent: String, Codable, Sendable {
    case requestStarted, queued, granted, handlerRejected, submissionRejected
    case registrationRejected, systemExpired, graceExpired, cancelledBeforeGrant
    case completed, endedIncomplete, unavailable, transferWake
}
public enum DiagnosticReportRejection: String, Codable, Sendable {
    case contentTooLarge, invalidExpiry, rateLimited, invalidRequest, unknown
}
public enum DiagnosticBackupIntent: String, Codable, Sendable { case automatic, explicit }
/// Closed stages/statuses and numeric/boolean facts only; no request/response prose.
public struct DiagnosticDetail: Codable, Sendable {
    public let stage: DiagnosticStage
    public let status: DiagnosticStatus
    public let correlationID: UUID
    public let nativeMethod: DiagnosticNativeMethod?
    public let nativeError: DiagnosticNativeError?
    public let httpStatus: Int?
    public let responseBytes: Int?
    public let available: Bool?
    public let wifi: Bool?
    public let expensive: Bool?
    public let constrained: Bool?
    public let authState: DiagnosticAuthState?
    public let googleError: DiagnosticGoogleError?
    public let backgroundEvent: DiagnosticBackgroundEvent?
    public let reportRejection: DiagnosticReportRejection?
    public let requestBytes: Int?
    public let foreground: Bool?
    public let backgroundExecutionAllowed: Bool?
    public let lowPowerMode: Bool?
    public let backupIntent: DiagnosticBackupIntent?
    public let policyCause: KnownCause?
    public let items: Int?
    public let pages: Int?
    public let reused: Bool?
    public init(stage: DiagnosticStage, status: DiagnosticStatus, correlationID: UUID,
                nativeMethod: DiagnosticNativeMethod? = nil, httpStatus: Int? = nil,
                responseBytes: Int? = nil, available: Bool? = nil, wifi: Bool? = nil,
                expensive: Bool? = nil, constrained: Bool? = nil, authState: DiagnosticAuthState? = nil,
                googleError: DiagnosticGoogleError? = nil, nativeError: DiagnosticNativeError? = nil,
                backgroundEvent: DiagnosticBackgroundEvent? = nil,
                reportRejection: DiagnosticReportRejection? = nil, requestBytes: Int? = nil,
                foreground: Bool? = nil, backgroundExecutionAllowed: Bool? = nil,
                lowPowerMode: Bool? = nil, backupIntent: DiagnosticBackupIntent? = nil,
                policyCause: KnownCause? = nil, items: Int? = nil, pages: Int? = nil, reused: Bool? = nil) {
        self.stage = stage; self.status = status; self.correlationID = correlationID
        self.nativeMethod = nativeMethod; self.httpStatus = httpStatus; self.responseBytes = responseBytes
        self.available = available; self.wifi = wifi; self.expensive = expensive; self.constrained = constrained
        self.authState = authState
        self.googleError = googleError
        self.nativeError = nativeError
        self.backgroundEvent = backgroundEvent; self.reportRejection = reportRejection
        self.requestBytes = requestBytes
        self.foreground = foreground; self.backgroundExecutionAllowed = backgroundExecutionAllowed
        self.lowPowerMode = lowPowerMode; self.backupIntent = backupIntent; self.policyCause = policyCause
        self.items = items; self.pages = pages; self.reused = reused
    }
}

/// Whitelisted values only. Never put raw response text, credentials, account names,
/// filenames, local paths, GPS, phone numbers or opaque receipts in diagnostic fields.
public struct SafeFailure: Error, Codable, Equatable, Sendable, CustomStringConvertible {
    public let category: FailureCategory
    public let domain: ErrorDomain
    public let code: Int?
    public let cause: KnownCause
    public init(_ category: FailureCategory, domain: ErrorDomain, code: Int? = nil, cause: KnownCause = .unknown) {
        self.category = category; self.domain = domain; self.code = code; self.cause = cause
    }
    /// Only closed enums and a numeric code; never raw NSError/userInfo prose.
    public var description: String {
        "\(category.rawValue)/\(domain.rawValue)/\(cause.rawValue)" + (code.map { " (\($0))" } ?? "")
    }
}

public struct EventContext: Codable, Sendable {
    public let runID: UUID?
    public let origin: EventOrigin
    public let destinationID: UUID?
    public let jobID: UUID?
    public let assetID: UUID?
    public let resourceID: UUID?
    public let cycleID: UUID?
    public let attempt: Int?
    public let diagnostic: DiagnosticDetail?
    public init(runID: UUID? = nil, origin: EventOrigin = .system, destinationID: UUID? = nil,
                jobID: UUID? = nil, assetID: UUID? = nil, resourceID: UUID? = nil,
                cycleID: UUID? = nil, attempt: Int? = nil, diagnostic: DiagnosticDetail? = nil) {
        self.runID = runID; self.origin = origin; self.destinationID = destinationID
        self.jobID = jobID; self.assetID = assetID; self.resourceID = resourceID
        self.cycleID = cycleID; self.attempt = attempt
        self.diagnostic = diagnostic
    }
}

public struct DiagnosticEvent: Codable, Sendable {
    public let sequence: Int64
    public let timestamp: Date
    public let version: String
    public let revision: String
    public let context: EventContext
    public let operation: EventOperation
    public let severity: EventSeverity
    public let decision: EventDecision
    public let fromState: String?
    public let toState: String?
    public let failure: SafeFailure?
    public let duration: TimeInterval?
    public let bytes: Int64?
    public let expectedBytes: Int64?
    public let part: Int?
    public init(sequence: Int64, timestamp: Date, version: String, revision: String,
                context: EventContext, operation: EventOperation, severity: EventSeverity,
                decision: EventDecision, fromState: String? = nil, toState: String? = nil,
                failure: SafeFailure? = nil, duration: TimeInterval? = nil, bytes: Int64? = nil,
                expectedBytes: Int64? = nil, part: Int? = nil) {
        self.sequence = sequence; self.timestamp = timestamp; self.version = version; self.revision = revision
        self.context = context; self.operation = operation; self.severity = severity; self.decision = decision
        self.fromState = fromState; self.toState = toState; self.failure = failure; self.duration = duration
        self.bytes = bytes; self.expectedBytes = expectedBytes; self.part = part
    }
}
