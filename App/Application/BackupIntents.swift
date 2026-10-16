import AppIntents
import CloudifiedCore

/// Shortcuts run the same actions as the Backup buttons. Start opens the app:
/// continued processing is tied to a person's action in the foreground.
struct StartBackupIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Backup"
    static let description: IntentDescription? = "Opens Cloudified and backs up to the connected destinations."
    static let supportedModes: IntentModes = .foreground(.immediate)

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let environment = AppEnvironment.shared
        if environment.pausedByUser { environment.requestResume() } else { environment.requestBackup() }
        return .result(dialog: environment.backupRequested
            ? "Cloudified is backing up."
            : "Cloudified could not start right now. Check the Backup screen.")
    }
}

struct PauseBackupIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Backup"
    static let description: IntentDescription? = "Pauses Cloudified until you resume it."
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let environment = AppEnvironment.shared
        environment.requestPause()
        return .result(dialog: environment.pausedByUser
            ? "Cloudified is paused until you resume it."
            : "Cloudified is changing state. Try again in a moment.")
    }
}

struct BackupStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Backup Status"
    static let description: IntentDescription? = "Reads saved and remaining counts from Cloudified's backup record."
    static let supportedModes: IntentModes = .background

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let environment = AppEnvironment.shared
        guard let ledger = environment.ledger else {
            return .result(dialog: "Cloudified's backup record is unavailable. Open the app.")
        }
        let snapshot = try await ledger.snapshot()
        guard snapshot.scanned else { return .result(dialog: "Cloudified has not finished scanning the library yet.") }
        var lines: [String] = []
        for provider in snapshot.providers where provider.destinationID != nil {
            guard provider.enabled else { lines.append("\(provider.provider.displayName) is off."); continue }
            guard let saved = provider.confirmed, let total = provider.total, let remaining = provider.remaining else { continue }
            lines.append("\(provider.provider.displayName): \(saved.formatted()) of \(total.formatted()) saved, \(remaining.formatted()) remaining.")
        }
        if lines.isEmpty { lines.append("No destination is connected.") }
        if environment.pausedByUser { lines.append("Backup is paused.") }
        let text = lines.joined(separator: " ")
        return .result(dialog: "\(text)")
    }
}

struct CloudifiedShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartBackupIntent(), phrases: ["Back up with \(.applicationName)", "Start \(.applicationName) backup"],
                    shortTitle: "Start Backup", systemImageName: "arrow.up.circle")
        AppShortcut(intent: PauseBackupIntent(), phrases: ["Pause \(.applicationName)", "Pause \(.applicationName) backup"],
                    shortTitle: "Pause Backup", systemImageName: "pause.circle")
        AppShortcut(intent: BackupStatusIntent(), phrases: ["\(.applicationName) status", "How is \(.applicationName) backup going"],
                    shortTitle: "Backup Status", systemImageName: "checkmark.icloud")
    }
}
