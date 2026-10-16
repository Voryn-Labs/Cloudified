import Foundation

/// Network availability used by system integrations.
public protocol SystemAdapterProtocol: Sendable {
    /// True if the device is currently connected to an unmetered Wi-Fi network.
    var isWiFiAvailable: Bool { get }
}
