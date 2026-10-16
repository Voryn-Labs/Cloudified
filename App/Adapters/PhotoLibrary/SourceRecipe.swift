import Foundation
import CloudifiedCore

/// Private, durable source-v1 recipe describing an asset's measured original resources,
/// metadata, and deterministic part splitting. Persisted into Ledger.saveSourceRecipe.
public struct SourceRecipe: Codable, Equatable, Sendable {
    public static let currentVersion = "source-v1"

    public let version: String
    public let assetLocalIdentifier: String
    public let generation: String
    public let mediaKind: MediaKind
    public let isLivePhoto: Bool
    public let resources: [SourceResourceDescriptor]
    public let metadata: SourceAssetMetadata
    public let videoSplits: [VideoSplitRecipe]

    public var videoSplit: VideoSplitRecipe? { videoSplits.first }

    public init(
        version: String = SourceRecipe.currentVersion,
        assetLocalIdentifier: String,
        generation: String,
        mediaKind: MediaKind,
        isLivePhoto: Bool,
        resources: [SourceResourceDescriptor],
        metadata: SourceAssetMetadata,
        videoSplits: [VideoSplitRecipe] = []
    ) throws {
        self.version = version
        self.assetLocalIdentifier = assetLocalIdentifier
        self.generation = generation
        self.mediaKind = mediaKind
        self.isLivePhoto = isLivePhoto
        self.resources = resources
        self.metadata = metadata
        self.videoSplits = videoSplits
        try validate()
    }

    public init(
        version: String = SourceRecipe.currentVersion,
        assetLocalIdentifier: String,
        generation: String,
        mediaKind: MediaKind,
        isLivePhoto: Bool,
        resources: [SourceResourceDescriptor],
        metadata: SourceAssetMetadata,
        videoSplit: VideoSplitRecipe?
    ) throws {
        try self.init(
            version: version,
            assetLocalIdentifier: assetLocalIdentifier,
            generation: generation,
            mediaKind: mediaKind,
            isLivePhoto: isLivePhoto,
            resources: resources,
            metadata: metadata,
            videoSplits: videoSplit.map { [$0] } ?? []
        )
    }

    enum CodingKeys: String, CodingKey {
        case version
        case assetLocalIdentifier
        case generation
        case mediaKind
        case isLivePhoto
        case resources
        case metadata
        case videoSplits
        case videoSplit
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decode(String.self, forKey: .version)
        self.assetLocalIdentifier = try container.decode(String.self, forKey: .assetLocalIdentifier)
        self.generation = try container.decode(String.self, forKey: .generation)
        self.mediaKind = try container.decode(MediaKind.self, forKey: .mediaKind)
        self.isLivePhoto = try container.decode(Bool.self, forKey: .isLivePhoto)
        self.resources = try container.decode([SourceResourceDescriptor].self, forKey: .resources)
        self.metadata = try container.decode(SourceAssetMetadata.self, forKey: .metadata)

        if let splits = try container.decodeIfPresent([VideoSplitRecipe].self, forKey: .videoSplits) {
            self.videoSplits = splits
        } else if let single = try container.decodeIfPresent(VideoSplitRecipe.self, forKey: .videoSplit) {
            self.videoSplits = [single]
        } else {
            self.videoSplits = []
        }

        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(assetLocalIdentifier, forKey: .assetLocalIdentifier)
        try container.encode(generation, forKey: .generation)
        try container.encode(mediaKind, forKey: .mediaKind)
        try container.encode(isLivePhoto, forKey: .isLivePhoto)
        try container.encode(resources, forKey: .resources)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(videoSplits, forKey: .videoSplits)
    }

    private func isHex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// Validates version, hash shapes, contiguous parts, and limits.
    public func validate() throws {
        guard version == SourceRecipe.currentVersion else {
            throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected)
        }
        guard isHex(generation, length: 64) else {
            throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected)
        }
        guard !assetLocalIdentifier.isEmpty,
              !assetLocalIdentifier.contains("\0"),
              assetLocalIdentifier.utf8.count <= 512 else {
            throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected)
        }
        guard !resources.isEmpty, resources.count <= 32 else {
            throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected)
        }

        for res in resources {
            guard isHex(res.sha256, length: 64),
                  isHex(res.sha1, length: 40),
                  res.byteCount > 0,
                  !res.uti.isEmpty,
                  !res.originalFilename.isEmpty,
                  res.role != .manifest else {
                throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected)
            }
            guard (res.resourceType == nil) == (res.selectorIndex == nil) else { throw CoreError.invalidContract }
            if let st = res.resourceType {
                guard st >= 0 else { throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected) }
            }
            if let idx = res.selectorIndex {
                guard idx >= 0 else { throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected) }
            }
        }

        guard videoSplits.count <= 32 else {
            throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected)
        }

        var splitKeys: Set<String> = []
        var mediaRequirementCount = resources.count

        for split in videoSplits {
            guard split.targetPartSize > 0, split.totalByteCount > 0,
                  split.parts.count > 1, split.parts.count <= 255,
                  split.targetPartSize <= 1_900_000_000,
                  isHex(split.originalSha256, length: 64),
                  splitKeys.insert("\(split.role.rawValue):\(split.originalSha256)").inserted,
                  resources.contains(where: { $0.sha256 == split.originalSha256 &&
                      $0.role == split.role && $0.byteCount == split.totalByteCount }) else {
                throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected)
            }
            mediaRequirementCount += split.parts.count - 1
            guard mediaRequirementCount <= 255 else { throw CoreError.invalidContract }

            var expectedOffset: Int64 = 0

            for (index, part) in split.parts.enumerated() {
                guard part.partIndex == index,
                      part.partCount == split.parts.count,
                      part.role == split.role,
                      part.offset == expectedOffset,
                      part.byteCount > 0,
                      isHex(part.sha256, length: 64),
                      isHex(part.sha1, length: 40) else {
                    throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected)
                }

                if index < split.parts.count - 1 {
                    guard part.byteCount == split.targetPartSize else {
                        throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected)
                    }
                } else {
                    guard part.byteCount <= split.targetPartSize else {
                        throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected)
                    }
                }

                guard expectedOffset <= Int64.max - part.byteCount else { throw CoreError.invalidContract }
                expectedOffset += part.byteCount
            }

            guard expectedOffset == split.totalByteCount else {
                throw SafeFailure(.invariant, domain: .photos, cause: .formatRejected)
            }
        }
    }

    /// Serializes this recipe to canonical UTF-8 JSON.
    /// Strictly guards against exceeding the Ledger's 256 KiB limit.
    public func encode() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 262_144 else {
            throw SafeFailure(.invariant, domain: .photos, cause: .invalidContract)
        }
        return data
    }

    /// Decodes a SourceRecipe from UTF-8 JSON.
    public static func decode(from data: Data) throws -> SourceRecipe {
        guard data.count <= 262_144 else {
            throw SafeFailure(.invariant, domain: .photos, cause: .invalidContract)
        }
        let decoder = JSONDecoder()
        let recipe = try decoder.decode(SourceRecipe.self, from: data)
        try recipe.validate()
        return recipe
    }
}

/// Description of an original asset resource measured directly from PhotoKit export.
public struct SourceResourceDescriptor: Codable, Equatable, Sendable {
    public let role: ResourceRole
    public let uti: String
    public let originalFilename: String
    public let sha256: String
    public let sha1: String
    public let byteCount: Int64
    public let photoKitResourceDataUTI: String?
    public let resourceType: Int?
    public let selectorIndex: Int?

    public init(
        role: ResourceRole,
        uti: String,
        originalFilename: String,
        sha256: String,
        sha1: String,
        byteCount: Int64,
        photoKitResourceDataUTI: String? = nil,
        resourceType: Int? = nil,
        selectorIndex: Int? = nil
    ) {
        self.role = role
        self.uti = uti
        self.originalFilename = originalFilename
        self.sha256 = sha256
        self.sha1 = sha1
        self.byteCount = byteCount
        self.photoKitResourceDataUTI = photoKitResourceDataUTI
        self.resourceType = resourceType
        self.selectorIndex = selectorIndex
    }

    enum CodingKeys: String, CodingKey {
        case role
        case uti
        case originalFilename
        case sha256
        case sha1
        case byteCount
        case photoKitResourceDataUTI
        case resourceType
        case selectorIndex
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decode(ResourceRole.self, forKey: .role)
        self.uti = try container.decode(String.self, forKey: .uti)
        self.originalFilename = try container.decode(String.self, forKey: .originalFilename)
        self.sha256 = try container.decode(String.self, forKey: .sha256)
        self.sha1 = try container.decode(String.self, forKey: .sha1)
        self.byteCount = try container.decode(Int64.self, forKey: .byteCount)
        self.photoKitResourceDataUTI = try container.decodeIfPresent(String.self, forKey: .photoKitResourceDataUTI)
        self.resourceType = try container.decodeIfPresent(Int.self, forKey: .resourceType)
        self.selectorIndex = try container.decodeIfPresent(Int.self, forKey: .selectorIndex)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(uti, forKey: .uti)
        try container.encode(originalFilename, forKey: .originalFilename)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(sha1, forKey: .sha1)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encodeIfPresent(photoKitResourceDataUTI, forKey: .photoKitResourceDataUTI)
        try container.encodeIfPresent(resourceType, forKey: .resourceType)
        try container.encodeIfPresent(selectorIndex, forKey: .selectorIndex)
    }

    public var originalContent: OriginalContent {
        OriginalContent(sha256: sha256, sha1: sha1, byteCount: byteCount, role: role)
    }
}

/// External asset metadata extracted from PHAsset properties.
public struct SourceAssetMetadata: Codable, Equatable, Sendable {
    public let creationDate: Date?
    public let modificationDate: Date?
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let durationSeconds: TimeInterval?
    public let isFavorite: Bool
    public let location: SourceLocationMetadata?

    public init(
        creationDate: Date?,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        durationSeconds: TimeInterval? = nil,
        isFavorite: Bool = false,
        location: SourceLocationMetadata? = nil
    ) {
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.isFavorite = isFavorite
        self.location = location
    }
}

/// External location metadata for archive manifests.
/// Strictly excluded from diagnostic event logs.
public struct SourceLocationMetadata: Codable, Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitude: Double?
    public let timestamp: Date?

    public init(latitude: Double, longitude: Double, altitude: Double? = nil, timestamp: Date? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.timestamp = timestamp
    }
}

/// Lossless video-part split recipe for Telegram large-file archival.
public struct VideoSplitRecipe: Codable, Equatable, Sendable {
    public let role: ResourceRole
    public let originalSha256: String
    public let targetPartSize: Int64
    public let totalByteCount: Int64
    public let parts: [VideoPartDescriptor]

    public init(
        role: ResourceRole = .video,
        originalSha256: String = "",
        targetPartSize: Int64,
        totalByteCount: Int64,
        parts: [VideoPartDescriptor]
    ) {
        self.role = role
        self.originalSha256 = originalSha256
        self.targetPartSize = targetPartSize
        self.totalByteCount = totalByteCount
        self.parts = parts
    }

    enum CodingKeys: String, CodingKey {
        case role
        case originalSha256
        case targetPartSize
        case totalByteCount
        case parts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decodeIfPresent(ResourceRole.self, forKey: .role) ?? .video
        self.originalSha256 = try container.decodeIfPresent(String.self, forKey: .originalSha256) ?? ""
        self.targetPartSize = try container.decode(Int64.self, forKey: .targetPartSize)
        self.totalByteCount = try container.decode(Int64.self, forKey: .totalByteCount)
        self.parts = try container.decode([VideoPartDescriptor].self, forKey: .parts)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(originalSha256, forKey: .originalSha256)
        try container.encode(targetPartSize, forKey: .targetPartSize)
        try container.encode(totalByteCount, forKey: .totalByteCount)
        try container.encode(parts, forKey: .parts)
    }
}

/// Descriptor for a single byte-exact part of a split video.
public struct VideoPartDescriptor: Codable, Equatable, Sendable {
    public let role: ResourceRole
    public let partIndex: Int
    public let partCount: Int
    public let offset: Int64
    public let byteCount: Int64
    public let sha256: String
    public let sha1: String

    public init(
        role: ResourceRole = .video,
        partIndex: Int,
        partCount: Int,
        offset: Int64,
        byteCount: Int64,
        sha256: String,
        sha1: String
    ) {
        self.role = role
        self.partIndex = partIndex
        self.partCount = partCount
        self.offset = offset
        self.byteCount = byteCount
        self.sha256 = sha256
        self.sha1 = sha1
    }

    enum CodingKeys: String, CodingKey {
        case role
        case partIndex
        case partCount
        case offset
        case byteCount
        case sha256
        case sha1
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.role = try container.decodeIfPresent(ResourceRole.self, forKey: .role) ?? .video
        self.partIndex = try container.decode(Int.self, forKey: .partIndex)
        self.partCount = try container.decode(Int.self, forKey: .partCount)
        self.offset = try container.decode(Int64.self, forKey: .offset)
        self.byteCount = try container.decode(Int64.self, forKey: .byteCount)
        self.sha256 = try container.decode(String.self, forKey: .sha256)
        self.sha1 = try container.decode(String.self, forKey: .sha1)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(partIndex, forKey: .partIndex)
        try container.encode(partCount, forKey: .partCount)
        try container.encode(offset, forKey: .offset)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(sha1, forKey: .sha1)
    }

    public var originalContent: OriginalContent {
        OriginalContent(
            sha256: sha256,
            sha1: sha1,
            byteCount: byteCount,
            role: role,
            partIndex: partIndex,
            partCount: partCount
        )
    }
}
