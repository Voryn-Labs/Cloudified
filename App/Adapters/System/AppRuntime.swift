import Foundation

/// LiveContainer publishes LC_HOME_PATH before handing control to its guest.
/// Use public process facts only; never probe private APIs or host entitlements.
enum AppRuntime {
    static let isHosted = isHosted(environment: ProcessInfo.processInfo.environment)
    static func isHosted(environment: [String: String]) -> Bool {
        guard let home = environment["LC_HOME_PATH"] else { return false }
        return !home.isEmpty
    }
    static var description: String { isHosted ? "LiveContainer · foreground backup" : "Installed app" }
}
