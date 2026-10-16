import Foundation

/// Protocol placeholder for TDLib bridge, document upload, and channel reconciliation.
/// Detailed implementation is assigned in Phase 4 (Builder) with bridge ownership review by Architect.
public protocol TelegramAdapterProtocol: Sendable {
    /// Current authentication status with Telegram.
    var isConnected: Bool { get }
}
