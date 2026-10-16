import Foundation

/// Authentication availability exposed by the Google Photos adapter.
public protocol GooglePhotosAdapterProtocol: Sendable {
    /// Current authentication status with Google Photos.
    var isConnected: Bool { get }
}
