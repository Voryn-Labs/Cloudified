import Foundation

/// Fallback policy for Google Photos Live Photo uploads when native pairing is unavailable.
public enum LivePhotoFallbackOption: String, CaseIterable, Identifiable, Sendable {
    case nativePair = "Paired originals (where supported)"
    case bothSeparately = "Both originals separately"
    case keyImageOnly = "Key image only"
    case motionVideoOnly = "Motion video only"

    public var id: String { rawValue }

    public var summaryDescription: String {
        switch self {
        case .nativePair:
            return "Preserves both originals and requests native Google pairing. Choose an explicit fallback if Google rejects pairing."
        case .bothSeparately:
            return "Recommended for preservation. Uploads both the high-resolution photo and full video component as separate original assets."
        case .keyImageOnly:
            return "Uploads only the high-resolution photo component. Motion video is omitted."
        case .motionVideoOnly:
            return "Uploads only the motion video component. Still photo is omitted."
        }
    }
}

/// Current step in Telegram TDLib authentication.
public enum TelegramAuthStep: String, Equatable, Sendable {
    case initializing = "Initializing secure session"
    case unconfigured = "API Credentials Required"
    case enterPhoneNumber = "Phone Number Required"
    case enterCode = "Verification Code Required"
    case enterPassword = "2FA Password Required"
    case enterEmail = "Email Address Required"
    case enterEmailCode = "Email Code Required"
    case otherDeviceConfirmation = "Confirm on Other Device"
    case registration = "Account Registration Required"
    case premiumPurchase = "Telegram Premium Required"
    case readyForChannel = "Ready (Map Channel)"
    case connected = "Connected"
    case closing = "Closing"
    case closed = "Closed"
    case error = "Error"
}

/// State representation for the Settings screen.
public struct SettingsViewState: Equatable, Sendable {
    public var controlsAvailable = false
    public var photosAccess: PhotosAccessState = .notDetermined
    public var lastBackgroundRun: String?
    public var backupCanPause = false
    public var automaticBackup = true
    public var notificationsEnabled = false
    public var notificationsRefused = false
    public var pauseInLowPower = false

    public var isGoogleEnabled: Bool
    public var isTelegramEnabled: Bool
    public var isWiFiOnlyEnabled: Bool
    public var livePhotoFallback: LivePhotoFallbackOption

    public var isGoogleConnected: Bool
    public var googleAccountEmail: String?
    public var isConnectingGoogle: Bool
    public var googleAuthErrorMessage: String?
    public var isSettlingGoogle: Bool

    public var isTelegramConnected: Bool
    public var telegramAccountName: String?
    public var telegramChannelName: String?
    public var telegramChatID: Int64?
    public var telegramAuthStep: TelegramAuthStep
    public var isConnectingTelegram: Bool
    public var telegramAuthErrorMessage: String?
    public var isSettlingTelegram: Bool

    public init(
        isGoogleEnabled: Bool = true,
        isTelegramEnabled: Bool = true,
        isWiFiOnlyEnabled: Bool = true,
        livePhotoFallback: LivePhotoFallbackOption = .nativePair,
        isGoogleConnected: Bool = false,
        googleAccountEmail: String? = nil,
        isConnectingGoogle: Bool = false,
        googleAuthErrorMessage: String? = nil,
        isSettlingGoogle: Bool = false,
        isTelegramConnected: Bool = false,
        telegramAccountName: String? = nil,
        telegramChannelName: String? = nil,
        telegramChatID: Int64? = nil,
        telegramAuthStep: TelegramAuthStep = .unconfigured,
        isConnectingTelegram: Bool = false,
        telegramAuthErrorMessage: String? = nil,
        isSettlingTelegram: Bool = false
    ) {
        self.isGoogleEnabled = isGoogleEnabled
        self.isTelegramEnabled = isTelegramEnabled
        self.isWiFiOnlyEnabled = isWiFiOnlyEnabled
        self.livePhotoFallback = livePhotoFallback
        self.isGoogleConnected = isGoogleConnected
        self.googleAccountEmail = googleAccountEmail
        self.isConnectingGoogle = isConnectingGoogle
        self.googleAuthErrorMessage = googleAuthErrorMessage
        self.isSettlingGoogle = isSettlingGoogle
        self.isTelegramConnected = isTelegramConnected
        self.telegramAccountName = telegramAccountName
        self.telegramChannelName = telegramChannelName
        self.telegramChatID = telegramChatID
        self.telegramAuthStep = telegramAuthStep
        self.isConnectingTelegram = isConnectingTelegram
        self.telegramAuthErrorMessage = telegramAuthErrorMessage
        self.isSettlingTelegram = isSettlingTelegram
    }
}
