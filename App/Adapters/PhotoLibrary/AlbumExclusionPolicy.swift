import Foundation
@preconcurrency import Photos
import CloudifiedCore

struct BackupAlbum: Identifiable, Sendable {
    let id: String
    let title: String
}

enum AlbumExclusionPolicy {
    static func albums() -> [BackupAlbum] {
        let fetched = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        return (0..<fetched.count).map { index in
            let album = fetched.object(at: index)
            return BackupAlbum(id: album.localIdentifier, title: album.localizedTitle ?? "Untitled album")
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private static func collections(_ ids: [String]) throws -> PHFetchResult<PHAssetCollection> {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw SafeFailure(.accessDenied, domain: .photos, cause: .permissionDenied)
        }
        let result = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: ids, options: nil)
        guard result.count == ids.count else {
            // Missing/deleted albums and permission-limited visibility are not
            // evidence that their former contents are eligible for upload.
            throw SafeFailure(.accessDenied, domain: .photos, cause: .exclusionUnavailable)
        }
        return result
    }
    static func refresh(_ ledger: Ledger, provider: Provider) async throws {
        let rules = try await ledger.albumExclusionRules(provider)
        if rules.albumIDs.isEmpty, try await ledger.exclusionReady(provider) { return }
        try await ledger.beginExclusionRefresh(provider, revision: rules.revision)
        if !rules.albumIDs.isEmpty {
            let albums = try collections(rules.albumIDs)
            for index in 0..<albums.count {
                try Task.checkCancellation()
                let assets = PHAsset.fetchAssets(in: albums.object(at: index), options: PhotoKitScanner.originalFetchOptions())
                var page: [String] = []
                for item in 0..<assets.count {
                    try Task.checkCancellation()
                    page.append(autoreleasepool { assets.object(at: item).localIdentifier })
                    if page.count == 200 {
                        try await ledger.stageExcludedAssets(page, provider: provider, revision: rules.revision)
                        page.removeAll(keepingCapacity: true)
                    }
                }
                if !page.isEmpty { try await ledger.stageExcludedAssets(page, provider: provider, revision: rules.revision) }
            }
        }
        try await ledger.finishExclusionRefresh(provider, revision: rules.revision)
    }
    static func mayUpload(_ localID: String, provider: Provider, ledger: Ledger) async throws -> Bool {
        let rules = try await ledger.albumExclusionRules(provider)
        guard !rules.albumIDs.isEmpty else { return true }
        do { _ = try collections(rules.albumIDs) }
        catch {
            try await ledger.beginExclusionRefresh(provider, revision: rules.revision)
            throw error
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localID], options: PhotoKitScanner.originalFetchOptions()).firstObject else {
            throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)
        }
        let albums = PHAssetCollection.fetchAssetCollectionsContaining(asset, with: .album, options: nil)
        let excluded = Set(rules.albumIDs)
        let blocked = (0..<albums.count).contains { excluded.contains(albums.object(at: $0).localIdentifier) }
        try await ledger.updateAssetExclusion(localID, provider: provider, revision: rules.revision, excluded: blocked)
        return !blocked
    }
}
