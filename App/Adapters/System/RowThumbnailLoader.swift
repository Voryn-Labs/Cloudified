import Foundation
import Combine
@preconcurrency import Photos
#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
public typealias PlatformImage = NSImage
#endif

/// PhotoKit hands back an immutable preview. Transfer that one reference to the
/// main actor; never access the cache or loader on PhotoKit's callback queue.
private struct ThumbnailResult: @unchecked Sendable { let image: PlatformImage }
@MainActor
final class RowThumbnailLoader: ObservableObject {
    @Published var image: PlatformImage?
    private var requestID: PHImageRequestID?
    private var generation = UUID()
    private static let loaders = NSHashTable<RowThumbnailLoader>.weakObjects()
    private static let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 100; cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()
    init() { Self.loaders.add(self) }
    func load(localIdentifier: String) {
        cancel()
        guard !localIdentifier.isEmpty else { return }
        if let cached = Self.cache.object(forKey: localIdentifier as NSString) { image = cached; return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: PhotoKitScanner.originalFetchOptions()).firstObject else { return }
        let token = generation
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false; options.deliveryMode = .fastFormat
        options.resizeMode = .fast; options.isSynchronous = false
        requestID = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: 96, height: 96), contentMode: .aspectFill, options: options) { [weak self] image, info in
            guard let image, (info?[PHImageCancelledKey] as? Bool) != true, info?[PHImageErrorKey] == nil else { return }
            let result = ThumbnailResult(image: image)
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                #if canImport(UIKit)
                let cost = result.image.cgImage.map { $0.bytesPerRow * $0.height } ?? Int(result.image.size.width * result.image.scale * result.image.size.height * result.image.scale * 4)
                #else
                let cost = result.image.representations.map { $0.pixelsWide * $0.pixelsHigh * 4 }.max() ?? 96 * 96 * 4
                #endif
                Self.cache.setObject(result.image, forKey: localIdentifier as NSString, cost: cost)
                self.image = result.image
            }
        }
    }
    func cancel() {
        generation = UUID()
        if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
        requestID = nil; image = nil
    }
    static func clearCache() {
        for loader in loaders.allObjects { loader.cancel() }
        cache.removeAllObjects()
    }
    deinit { if let requestID { PHImageManager.default().cancelImageRequest(requestID) } }
}
