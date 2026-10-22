import Foundation

public enum PhotosAccessState: Equatable, Sendable {
    case notDetermined, limited, full, denied, restricted
    public var canRead: Bool { self == .limited || self == .full }
    public var description: String {
        switch self {
        case .notDetermined: return "Photos access needed"
        case .limited: return "Selected photos only"
        case .full: return "Full Photos access"
        case .denied: return "Photos access denied"
        case .restricted: return "Photos access restricted by this device"
        }
    }
}

public enum OverallActivityState: Equatable, Sendable {
    case notScanned
    case idle
    case scanning
    case preparing
    case checking
    case uploading
    case finalizing
    case waiting(reason: String)
    case paused
    case complete
    case needsAttention(reason: String)

    public var title: String {
        switch self {
        case .notScanned:
            return "Not scanned"
        case .idle:
            return "Idle"
        case .scanning:
            return "Scanning library"
        case .preparing:
            return "Preparing media"
        case .checking:
            return "Checking remote status"
        case .uploading:
            return "Uploading"
        case .finalizing:
            return "Finalizing"
        case .waiting(let reason):
            return "Waiting: \(reason)"
        case .paused:
            return "Paused"
        case .complete:
            return "Backup complete"
        case .needsAttention(let reason):
            return "Needs attention: \(reason)"
        }
    }

    public var isTransferring: Bool {
        switch self {
        case .uploading, .finalizing:
            return true
        default:
            return false
        }
    }
}

public struct ProviderCardState: Equatable, Sendable {
    public enum Attention: Equatable, Sendable { case signIn, storage, rateLimit, account, connection
        public var title: String {
            switch self {
            case .signIn: return "Sign-in needed"
            case .storage: return "Storage limit"
            case .rateLimit: return "Temporary limit"
            case .account: return "Account needs attention"
            case .connection: return "Connection needs attention"
            }
        }
        public var actionTitle: String? {
            switch self {
            case .signIn: return "Sign in again"
            case .storage: return "Manage storage"
            case .account: return "Review account settings"
            case .connection: return "Open connection settings"
            case .rateLimit: return nil
            }
        }
    }
    public let name: String
    public var attention: Attention?
    public var attentionMessage: String?
    public var isEnabled: Bool
    public var isConnected: Bool
    public var accountIdentifier: String?
    public var channelIdentifier: String?
    public var currentActivity: String
    public var savedCount: Int?
    public var remainingCount: Int?
    public var totalCount: Int?
    public var waitingCount: Int?
    public var failedCount: Int?
    public var lastConfirmedDate: Date?
    public var retainedTransferCount: Int?
    public var protectedUnresolvedCount: Int?

    public init(
        name: String,
        isEnabled: Bool = true,
        isConnected: Bool = false,
        accountIdentifier: String? = nil,
        channelIdentifier: String? = nil,
        currentActivity: String = "Not connected",
        savedCount: Int? = nil,
        remainingCount: Int? = nil,
        totalCount: Int? = nil,
        waitingCount: Int? = nil,
        failedCount: Int? = nil,
        lastConfirmedDate: Date? = nil
    ) {
        self.name = name
        self.isEnabled = isEnabled
        self.isConnected = isConnected
        self.accountIdentifier = accountIdentifier
        self.channelIdentifier = channelIdentifier
        self.currentActivity = currentActivity
        self.savedCount = savedCount
        self.remainingCount = remainingCount
        self.totalCount = totalCount
        self.waitingCount = waitingCount
        self.failedCount = failedCount
        self.lastConfirmedDate = lastConfirmedDate
    }

    public var connectionDescription: String {
        guard isConnected else { return "Not connected" }
        if let account = accountIdentifier {
            if let channel = channelIdentifier {
                return "\(account) → \(channel)"
            }
            return account
        }
        return "Connected"
    }

    public var remainingOutOfTotalText: String {
        let remainingStr = remainingCount.map(String.init) ?? "--"
        let totalStr = totalCount.map(String.init) ?? "--"
        return "\(remainingStr) remaining out of \(totalStr)"
    }

    public var confirmedText: String {
        let savedStr = savedCount.map(String.init) ?? "--"
        let totalStr = totalCount.map(String.init) ?? "--"
        return "\(savedStr) saved out of \(totalStr)"
    }
}

public struct MediaSectionState: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    public var totalCount: Int?
    public var googleSaved: Int?
    public var googleRemaining: Int?
    public var googleFailed: Int?
    public var telegramSaved: Int?
    public var telegramRemaining: Int?
    public var telegramFailed: Int?
    public var activeOperation: String?
    public var byteProgress: String?

    public init(
        title: String,
        subtitle: String,
        totalCount: Int? = nil,
        googleSaved: Int? = nil,
        googleRemaining: Int? = nil,
        googleFailed: Int? = nil,
        telegramSaved: Int? = nil,
        telegramRemaining: Int? = nil,
        telegramFailed: Int? = nil,
        activeOperation: String? = nil,
        byteProgress: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.totalCount = totalCount
        self.googleSaved = googleSaved
        self.googleRemaining = googleRemaining
        self.googleFailed = googleFailed
        self.telegramSaved = telegramSaved
        self.telegramRemaining = telegramRemaining
        self.telegramFailed = telegramFailed
        self.activeOperation = activeOperation
        self.byteProgress = byteProgress
    }
}

public struct CurrentTransferState: Identifiable, Equatable, Sendable {
    public let id: String
    public var activity: String
    public let filename: String
    public let mediaType: String
    public let provider: String
    public var bytesSent: Int64
    public var totalBytes: Int64?
    public var componentOrPart: String?
    public var attemptNumber: Int?
    public let maxAttempts: Int

    public init(
        id: String,
        activity: String,
        filename: String,
        mediaType: String,
        provider: String,
        bytesSent: Int64 = 0,
        totalBytes: Int64? = nil,
        componentOrPart: String? = nil,
        attemptNumber: Int? = nil,
        maxAttempts: Int = 3
    ) {
        self.id = id; self.activity = activity
        self.filename = filename
        self.mediaType = mediaType
        self.provider = provider
        self.bytesSent = bytesSent
        self.totalBytes = totalBytes
        self.componentOrPart = componentOrPart
        self.attemptNumber = attemptNumber
        self.maxAttempts = maxAttempts
    }

    public var fractionCompleted: Double? {
        guard let total = totalBytes, total > 0 else { return nil }
        return min(1.0, max(0.0, Double(bytesSent) / Double(total)))
    }

    public var percentageText: String {
        if let fraction = fractionCompleted {
            if fraction >= 1.0 {
                return "Finalizing"
            }
            return String(format: "%.1f%%", fraction * 100.0)
        }
        return "--%"
    }

    public var byteProgressText: String {
        let sentStr = ByteCountFormatter.string(fromByteCount: bytesSent, countStyle: .file)
        if let total = totalBytes, total > 0 {
            let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(sentStr) of \(totalStr)"
        }
        return sentStr
    }

    public var attemptText: String {
        return attemptNumber.map { "Attempt \($0) of \(maxAttempts)" } ?? "Attempt not started"
    }
}

public struct DashboardViewState: Equatable, Sendable {
    public var photosAccess: PhotosAccessState = .notDetermined
    public var isReadingLibrary = false
    public var overallState: OverallActivityState
    public var waitingOrErrorReason: String?
    public var accessibleLibraryTotal: Int?
    public var scanTimestamp: Date?
    public var permissionScopeDescription: String
    public var savedToBothCount: Int?

    public var googleStatus: ProviderCardState
    public var telegramStatus: ProviderCardState

    public var photosSection: MediaSectionState
    public var videosSection: MediaSectionState

    public var canPause = false
    public var canResume = false
    public var controlsAvailable = false
    public var controlActivity: String?
    public var currentTransfers: [CurrentTransferState]

    public var backgroundStatus: String?
    public var backgroundRefreshOff = false
    public var lowPowerMode = false
    public var interruptedRunNotice: String?
    public var lastBackgroundRun: String?

    public init(
        overallState: OverallActivityState = .notScanned,
        waitingOrErrorReason: String? = nil,
        accessibleLibraryTotal: Int? = nil,
        scanTimestamp: Date? = nil,
        permissionScopeDescription: String = "Not determined",
        savedToBothCount: Int? = nil,
        googleStatus: ProviderCardState = ProviderCardState(name: "Google Photos"),
        telegramStatus: ProviderCardState = ProviderCardState(name: "Telegram"),
        photosSection: MediaSectionState = MediaSectionState(
            title: "Photos",
            subtitle: "Live Photos are included; motion does not inflate video count"
        ),
        videosSection: MediaSectionState = MediaSectionState(
            title: "Videos",
            subtitle: "Full original quality; independent concurrent queue"
        ),
        currentTransfers: [CurrentTransferState] = []
    ) {
        self.overallState = overallState
        self.waitingOrErrorReason = waitingOrErrorReason
        self.accessibleLibraryTotal = accessibleLibraryTotal
        self.scanTimestamp = scanTimestamp
        self.permissionScopeDescription = permissionScopeDescription
        self.savedToBothCount = savedToBothCount
        self.googleStatus = googleStatus
        self.telegramStatus = telegramStatus
        self.photosSection = photosSection
        self.videosSection = videosSection
        self.currentTransfers = currentTransfers
    }

    public var canStartBackup: Bool {
        return (googleStatus.isConnected && googleStatus.isEnabled) || (telegramStatus.isConnected && telegramStatus.isEnabled)
    }

    public var summaryTitle: String {
        if let controlActivity { return controlActivity }
        if waitingForProtectedSends { return "Awaiting verification" }
        switch overallState {
        case .paused: return "Backup paused"
        case .complete: return "Up to date"
        case .waiting: return "Backup waiting"
        case .needsAttention: return "Check backup"
        case .notScanned: return "Set up backup"
        default: return workInProgress ? "Backup active" : "Ready to back up"
        }
    }

    public var workInProgress: Bool {
        switch overallState {
        case .scanning, .preparing, .checking, .uploading, .finalizing:
            return true
        default:
            return canPause || !currentTransfers.isEmpty
        }
    }

    public var keepAwakeAllowed: Bool {
        guard controlActivity == nil else { return false }
        switch overallState {
        case .paused, .complete, .notScanned: return false
        default: break
        }
        if !currentTransfers.isEmpty { return true }
        if overallState == .scanning { return true }
        return workInProgress && !waitingForProtectedSends
    }

    public var waitingForProtectedSends: Bool {
        guard currentTransfers.isEmpty, overallState != .scanning, overallState != .paused,
              telegramStatus.isEnabled, telegramStatus.isConnected,
              let remaining = telegramStatus.remainingCount, remaining > 0,
              remaining <= (telegramStatus.protectedUnresolvedCount ?? 0) else { return false }
        return !googleStatus.isEnabled || !googleStatus.isConnected || googleStatus.remainingCount == 0
    }
}
