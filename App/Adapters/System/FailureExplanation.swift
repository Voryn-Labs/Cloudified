import Foundation
import CloudifiedCore

enum FailureExplanation {
    static func message(_ failure: SafeFailure) -> String {
        if failure.domain == .fileSystem {
            switch failure.cause {
            case .storageUnavailable:
                return "Cloudified could not prepare its local app storage\(failure.code.map { " (error \($0))" } ?? ""). Close and reopen the app, then retry. If it persists, export diagnostics."
            case .storagePathConflict:
                return "Cloudified found a file or redirected path where a local storage folder is required. Setup stopped to protect existing data. Export diagnostics; do not delete the app's database."
            case .permissionDenied:
                return "iOS denied access to Cloudified's local storage\(failure.code.map { " (error \($0))" } ?? ""). Unlock the iPhone, reopen the app and retry. This is a local storage error."
            default: break
            }
        }
        switch failure.cause {
        case .databaseKeyUnavailable: return "Cloudified cannot unlock its local Telegram connection data. Try the original signing identity first. Settings → Telegram offers a local connection reset only when no unresolved uploads need that data. Your uploaded channel files are unchanged."
        case .nativeResponseInvalid: return "Cloudified could not decode a Telegram response. This is a connection protocol error, not an unsupported photo format. Protected uploads require recovery before another send."
        case .nativeResponseLimit: return "A Telegram response exceeded Cloudified's decoder capacity. Existing uploads remain protected while the connection recovers. Export diagnostics if this repeats."
        case .identityUnverified: return "Google could not verify this signed-in account\(failure.code.map { " (HTTP \($0))" } ?? ""). Open Logs for the identity or token-verification result."
        case .pairingUnverified: return "Google could not verify this Live Photo as one paired item. Choose a Live Photo fallback in Settings, or retry this item in Activity. Accepted components stay protected from duplicate uploads."
        case .pendingSendUnmatched: return "Telegram has not provided a verifiable result for this file. It is not counted as saved. Its original stays protected while other eligible files continue."
        case .privateChannelRequired: return "Telegram requires a channel you own, with no public username and auto-delete turned off."
        case .accountChanged: return "The account or channel differs from this upload's verified destination. Reconnect the original mapping."
        case .loginRequired: return "Authentication is required. Open this destination in Settings."
        case .permissionDenied: return "Access was denied. Check Photos permission or the destination's permissions."
        case .insufficientSpace: return "More device space is needed to stage the original safely. Other admissible assets can continue."
        case .formatRejected: return "The original format or resource layout is unsupported by this destination. No quality conversion was made."
        case .contentChanged: return "This asset changed while its original was being prepared. Refresh the library and try again."
        case .sourceMissing: return "The original asset is no longer available in the accessible Photos library."
        case .interrupted: return "Work was interrupted. Uncertain sends are checked before another upload."
        case .serverRateLimit: return "The destination requested a delay. Its retry time is retained; the other destination can continue."
        case .deadlineExceeded: return "The request timed out. A missing acknowledgement is checked before another send."
        case .offline: return "Waiting for a network connection. A network path does not guarantee internet access."
        case .lowDataMode: return "Waiting for Low Data Mode to be turned off for this network."
        case .wifiRequired: return "Waiting for Wi-Fi under your network preference."
        case .thermalPressure: return "Waiting for the device to cool before preparing more originals."
        case .lowPowerMode: return "Paused while Low Power Mode is on, as set in Settings."
        case .backgroundRestricted: return "Background execution is unavailable. Open Cloudified to continue this backup."
        case .backgroundExpired: return "Background processing ended or was stopped from its system activity. Submitted Google files remain protected; reopen Cloudified to continue."
        case .operationBusy: return "Cloudified is finishing another account or recovery action. Try again when it finishes."
        case .outcomeUnknown: return "The destination has not confirmed whether this file was saved. Cloudified checks the existing upload before sending another copy."
        case .incompleteHistory: return "The destination's file history could not be fully checked. Cloudified needs a verified result before sending this file again."
        case .persistenceFailed: return "The local ledger could not persist a change. Saved status cannot be confirmed."
        case .invalidContract: return "An internal consistency check failed. Export the safe diagnostics for investigation."
        case .quotaExceeded: return "The destination reports a storage limit. Check its account status."
        case .providerRejected: return "The destination rejected this operation\(failure.code.map { " (code \($0), \(failure.domain.rawValue))" } ?? ""). Open Logs for the failed request."
        case .disabled: return "This destination is disabled; its backlog is retained."
        case .paused: return "Backup is paused."
        case .storageUnavailable, .storagePathConflict: return "Local app storage is unavailable. Export diagnostics before changing stored data."
        case .setupUnavailable: return "Cloudified could not initialize this connection. This is an app setup failure, not an unconfirmed upload. Open Logs for the startup error."
        case .initializationFailed: return "Telegram session initialization failed. Retry starting Telegram; Logs contain the failed setup stage and native error code."
        case .verificationFailed: return "Browser sign-in completed, but the app could not verify the Photos connection. Retry verification or check Logs for the failed stage."
        case .networkRequestFailed: return "A network request failed\(failure.code.map { " (code \($0))" } ?? ""). This does not prove the phone is offline. Check Logs for the failed stage."
        case .unknown: return "The cause is unknown (\(failure.category.rawValue), \(failure.domain.rawValue)\(failure.code.map { ", code \($0)" } ?? ""))."
        case .phoneNumberInvalid: return "Enter the full international phone number, starting with + and the country code. Spaces and brackets are allowed. Telegram must accept this number before sending a code."
        case .phoneNumberBanned: return "Telegram reports that this phone number is banned. This cannot be fixed by retrying Cloudified."
        case .applicationCredentialsRejected: return "Telegram rejected the API application credentials. Check the API ID and hash together in Settings; Logs contain the exact safe rejection name."
        case .authenticationRejected: return "Telegram rejected this sign-in step. Open Logs for the safe rejection name before retrying."
        }
    }
    static func remedy(_ failure: SafeFailure?) -> String {
        guard let failure else { return "Check the pending operation's status before retrying." }
        if failure.domain == .fileSystem && failure.cause == .permissionDenied {
            return "Unlock the iPhone, reopen Cloudified and retry. Check the local storage error code."
        }
        switch failure.cause {
        case .databaseKeyUnavailable: return "Restore the original signing identity or review Reset local Telegram connection in Settings → Telegram. If protected uploads block reset, keep the app data and share diagnostics."
        case .loginRequired, .identityUnverified, .accountChanged: return "Reconnect the correct destination in Settings."
        case .pendingSendUnmatched, .outcomeUnknown, .incompleteHistory: return "Use Verify upload with the same account and channel. If it stays waiting, upload diagnostics from Report a problem. Deleting or relinking the app does not prove the file was saved."
        case .insufficientSpace: return "Free device space, then retry this asset."
        case .permissionDenied, .sourceMissing: return "Check Photos access and availability of the original."
        case .pairingUnverified: return "Select an explicit Google Live Photo policy."
        case .serverRateLimit, .offline, .wifiRequired: return "Wait for the listed retry time or an allowed network."
        case .storageUnavailable: return "Unlock the iPhone, reopen Cloudified and retry. Export diagnostics if setup still fails."
        case .storagePathConflict: return "Export diagnostics for investigation. Keep existing local data intact."
        default: return "Review the safe error code and export diagnostics if the error persists."
        }
    }
    static func requiresReconciliation(_ failure: SafeFailure?) -> Bool {
        guard let failure else { return false }
        return [.outcomeUnknown, .pendingSendUnmatched, .incompleteHistory].contains(failure.cause)
    }
}
