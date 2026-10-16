import Foundation
import Photos
import CryptoKit
import CloudifiedCore

/// PhotoKit enumeration engine handling access verification, metadata scanning, and bounded pagination.
public enum PhotoKitScanner {
    public static let maxPageSize = 200
    static func originalFetchOptions() -> PHFetchOptions {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        options.includeAllBurstAssets = true
        return options
    }

    /// Refetch a current PhotoKit snapshot; checking an already fetched immutable
    /// PHAsset again cannot establish that it stayed unchanged during export.
    public static func verifyGeneration(_ identity: AssetIdentity) throws {
        guard let current = PHAsset.fetchAssets(withLocalIdentifiers: [identity.localIdentifier], options: originalFetchOptions()).firstObject else {
            throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)
        }
        guard computeGeneration(for: current) == identity.generation else {
            throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .contentChanged)
        }
    }

    /// Computes a canonical deterministic generation hash for a local PHAsset.
    public static func computeGeneration(for asset: PHAsset) -> String {
        var descriptor = "source-generation-v2:\(asset.localIdentifier):\(asset.pixelWidth)x\(asset.pixelHeight):\(asset.mediaType.rawValue)"
        if let creation = asset.creationDate {
            descriptor += ":c=\(creation.timeIntervalSince1970)"
        }
        if let modification = asset.modificationDate {
            descriptor += ":m=\(modification.timeIntervalSince1970)"
        }
        if asset.duration > 0 {
            descriptor += ":d=\(asset.duration)"
        }
        descriptor += ":s=\(asset.mediaSubtypes.rawValue)"
        descriptor += ":f=\(asset.isFavorite)"
        if let location = asset.location {
            descriptor += ":l=\(location.coordinate.latitude),\(location.coordinate.longitude),\(location.altitude),\(location.timestamp.timeIntervalSince1970)"
        }

        let hash = SHA256.hash(data: Data(descriptor.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Determines the Core MediaKind for a PHAsset.
    /// Live Photos are classified as .photo once per architecture specification.
    public static func kind(for asset: PHAsset) -> MediaKind {
        if asset.mediaType == .video {
            return .video
        }
        return .photo
    }

    /// Maps a PHAssetResourceType to a core ResourceRole.
    /// Excludes rendered derivatives and adjustment metadata.
    public static func role(for type: PHAssetResourceType) -> ResourceRole? {
        switch type {
        case .photo:
            return .still
        case .pairedVideo:
            return .motion
        case .video:
            return .video
        case .alternatePhoto:
            return .auxiliary
        default:
            return nil
        }
    }

    /// Checks if a resource type represents an original camera resource rather than an edited preview.
    public static func isOriginalResourceType(_ type: PHAssetResourceType) -> Bool {
        return role(for: type) != nil
    }

    static func identity(for asset: PHAsset) -> AssetIdentity {
        AssetIdentity(id: UUID(), localIdentifier: asset.localIdentifier,
                      generation: computeGeneration(for: asset), kind: kind(for: asset))
    }

    /// A change token belongs to the scan it was read before. UserDefaults is
    /// deleted with the app, like the ledger; a token for another scan is ignored.
    private struct ChangeTokenRecord: Codable {
        let scanID: UUID
        let token: Data
        let fullScanAt: Date
        // Required on decode: older records may describe a limited-access scan.
        let fullAccess: Bool
        let coverageVersion: Int
    }
    private static let tokenKey = "CloudifiedScanChangeToken"
    /// A full scan at least daily catches anything change tracking did not report.
    static let fullScanInterval: TimeInterval = 24 * 3600
    /// Past this many changed assets a full scan costs about the same.
    static let maxIncrementalChanges = 20_000

    private static func loadTokenRecord() -> ChangeTokenRecord? {
        UserDefaults.standard.data(forKey: tokenKey).flatMap { try? JSONDecoder().decode(ChangeTokenRecord.self, from: $0) }
    }
    private static func saveToken(_ token: PHPersistentChangeToken, scanID: UUID, fullScanAt: Date) {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              let archived = try? NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true),
            let data = try? JSONEncoder().encode(ChangeTokenRecord(scanID: scanID, token: archived, fullScanAt: fullScanAt, fullAccess: true, coverageVersion: 2)) else {
            UserDefaults.standard.removeObject(forKey: tokenKey); return
        }
        UserDefaults.standard.set(data, forKey: tokenKey)
    }

    /// Re-reads only assets PhotoKit reports as inserted, updated or deleted since
    /// the saved token. nil means a full scan is required: limited access, no or
    /// expired token, unavailable change details, too many changes, or the daily
    /// full scan is due.
    private static func incrementalScan(
        ledger: Ledger, options: PHFetchOptions, progress: (@Sendable (Int, Int) -> Void)?
    ) async throws -> (scanID: UUID, totalDiscovered: Int, fullScanAt: Date)? {
        guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized,
              let record = loadTokenRecord(), record.fullAccess, record.coverageVersion == 2,
              (0..<fullScanInterval).contains(Date().timeIntervalSince(record.fullScanAt)),
              let current = try await ledger.currentLibraryScan(), current.complete, current.id == record.scanID,
              let token = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: record.token)
        else { return nil }
        var changed = Set<String>()
        do {
            for change in try PHPhotoLibrary.shared().fetchPersistentChanges(since: token) {
                try Task.checkCancellation()
                let details = try change.changeDetails(for: .asset)
                changed.formUnion(details.insertedLocalIdentifiers)
                changed.formUnion(details.updatedLocalIdentifiers)
                changed.formUnion(details.deletedLocalIdentifiers)
                if changed.count > maxIncrementalChanges { return nil }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return nil
        }
        if changed.isEmpty {
            progress?(0, 0)
            return (current.id, try await ledger.snapshot().libraryTotal ?? 0, record.fullScanAt)
        }
        let ids = Array(changed)
        let begun = try await ledger.beginIncrementalScan(from: current.id, dropping: ids)
        var registered = 0, start = 0
        while start < ids.count {
            try Task.checkCancellation()
            let slice = Array(ids[start..<min(start + maxPageSize, ids.count)])
            let fetched = PHAsset.fetchAssets(withLocalIdentifiers: slice, options: options)
            var page: [AssetIdentity] = []
            page.reserveCapacity(fetched.count)
            for i in 0..<fetched.count { page.append(identity(for: fetched.object(at: i))) }
            if !page.isEmpty { _ = try await ledger.registerAssets(page, scanID: begun.id) }
            registered += page.count; start += slice.count
            progress?(start, ids.count)
        }
        try await ledger.completeScan(begun.id)
        progress?(ids.count, ids.count)
        return (begun.id, begun.carried + registered, record.fullScanAt)
    }

    /// Metadata pass over the accessible library, in Ledger pages of <= 200 items.
    /// `full: false` allows an incremental pass from the saved change token.
    public static func scanAccessibleLibrary(
        ledger: Ledger,
        fetchOptions: PHFetchOptions? = nil,
        full: Bool = true,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> (scanID: UUID, totalDiscovered: Int) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw SafeFailure(.accessDenied, domain: .photos, cause: .permissionDenied)
        }

        let options: PHFetchOptions
        if let fetchOptions {
            guard let copied = fetchOptions.copy() as? PHFetchOptions else { throw CoreError.invalidContract }
            options = copied
        } else { options = originalFetchOptions() }
        let mediaPredicate = NSPredicate(
            format: "mediaType == %d OR mediaType == %d",
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
        if let existing = options.predicate {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [existing, mediaPredicate])
        } else {
            options.predicate = mediaPredicate
        }
        if options.sortDescriptors == nil || options.sortDescriptors?.isEmpty == true {
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        }

        // Read before enumerating: changes made during the scan are re-read next time.
        let startToken = PHPhotoLibrary.shared().currentChangeToken
        // Custom fetch options and limited authorization do not describe the
        // whole library. Never reuse or publish their scan as a full baseline.
        let fullAccess = status == .authorized && fetchOptions == nil
        if !fullAccess { UserDefaults.standard.removeObject(forKey: tokenKey) }
        if !full, fullAccess, let incremental = try await incrementalScan(ledger: ledger, options: options, progress: progress) {
            saveToken(startToken, scanID: incremental.scanID, fullScanAt: incremental.fullScanAt)
            return (incremental.scanID, incremental.totalDiscovered)
        }

        let scanID = try await ledger.beginScan()
        let fetchResult = PHAsset.fetchAssets(with: options)
        let totalCount = fetchResult.count

        var page: [AssetIdentity] = []
        page.reserveCapacity(maxPageSize)

        for i in 0..<totalCount {
            try Task.checkCancellation()
            page.append(identity(for: fetchResult.object(at: i)))

            if page.count == maxPageSize {
                _ = try await ledger.registerAssets(page, scanID: scanID)
                page.removeAll(keepingCapacity: true)
                progress?(i + 1, totalCount)
            }
        }

        if !page.isEmpty {
            _ = try await ledger.registerAssets(page, scanID: scanID)
        }
        progress?(totalCount, totalCount)

        try await ledger.completeScan(scanID)
        if fullAccess && PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized {
            saveToken(startToken, scanID: scanID, fullScanAt: Date())
        } else { UserDefaults.standard.removeObject(forKey: tokenKey) }
        return (scanID, totalCount)
    }
}
