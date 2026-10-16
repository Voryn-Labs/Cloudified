import Foundation
import CloudifiedCore

/// Protocol defining PhotoKit library operations, scanning, and original media preparation.
public protocol PhotoLibraryAdapterProtocol: Sendable {
    /// Performs an accessible PhotoKit scan, registering assets into the Ledger in bounded pages.
    /// `full: false` allows an incremental pass from PhotoKit persistent changes.
    /// `progress` receives (done, total) after each stored page.
    func scanLibrary(full: Bool, progress: (@Sendable (Int, Int) -> Void)?) async throws -> (scanID: UUID, totalDiscovered: Int)

    /// Incrementally measures an asset and enqueues provider-specific plans into the Ledger.
    func planAsset(
        asset: AssetIdentity,
        googleDestination: Destination?,
        telegramDestination: Destination?,
        googleLiveFallback: LivePhotoFallbackOption,
        videoPartThreshold: Int64
    ) async throws

    /// Returns the active OriginalPreparer instance for the engine.
    var originalPreparer: any OriginalPreparer { get }
}
