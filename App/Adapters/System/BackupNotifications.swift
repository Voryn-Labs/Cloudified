import Foundation
import UserNotifications
import CloudifiedCore

/// Opt-in local notifications when a background run ends while the app is not
/// in front. Text comes only from the run record and a ledger snapshot.
@MainActor
enum BackupNotifications {
    private static let key = "CloudifiedNotifications"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: key) }

    /// Returns the stored choice; iOS can refuse or have been refused before.
    static func setEnabled(_ on: Bool) async -> Bool {
        guard on else { UserDefaults.standard.set(false, forKey: key); return false }
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])) ?? false
        UserDefaults.standard.set(granted, forKey: key)
        return granted
    }

    static func runEnded(_ run: BackgroundRun, providers: [ProviderSnapshot]) {
        guard enabled, let outcome = run.outcome, outcome != .interrupted else { return }
        var lines: [String] = []
        if let start = run.savedAtStart, let end = run.savedAtEnd {
            lines.append("\(max(0, end - start)) saved in the background.")
        }
        let left = providers.filter { $0.enabled && $0.destinationID != nil }.compactMap { provider -> String? in
            guard let remaining = provider.remaining, remaining > 0 else { return nil }
            return "\(provider.provider == .google ? "Google Photos" : "Telegram"): \(remaining) left"
        }
        if !left.isEmpty { lines.append(left.joined(separator: " · ") + ".") }
        let content = UNMutableNotificationContent()
        switch outcome {
        case .finished:
            content.title = "Backup complete"
        case .incomplete:
            content.title = "Backup stopped"
            lines.append("Open Cloudified to continue.")
        case .expired:
            content.title = "iOS ended background backup"
            lines.append("Open Cloudified to continue, or keep the phone awake while charging.")
        case .interrupted:
            return
        }
        content.body = lines.joined(separator: " ")
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: run.id.uuidString, content: content, trigger: nil)) { _ in }
    }
}
