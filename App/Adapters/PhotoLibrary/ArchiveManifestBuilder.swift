import Foundation
import CryptoKit
import CloudifiedCore

/// Stable archive recipe excludes PhotoKit IDs/generation and final remote IDs.
/// The uploaded document also records confirmed message references and full
/// original hashes/filenames/UTIs, so lossless parts can be reconstructed/verified.
public enum ArchiveManifestBuilder {
    public static let schemaVersion = "manifest-v2"
    public struct ManifestResourceEntry: Codable, Sendable {
        public let role: ResourceRole
        public let tag: String
        public let sha256: String
        public let sha1: String
        public let byteCount: Int64
        public let partIndex: Int?
        public let partCount: Int?
        public let originalSha256: String?
        public let offset: Int64?
        public init(role: ResourceRole, tag: String, sha256: String, sha1: String, byteCount: Int64,
                    partIndex: Int? = nil, partCount: Int? = nil,
                    originalSha256: String? = nil, offset: Int64? = nil) {
            self.role = role; self.tag = tag; self.sha256 = sha256; self.sha1 = sha1; self.byteCount = byteCount
            self.partIndex = partIndex; self.partCount = partCount
            self.originalSha256 = originalSha256; self.offset = offset
        }
    }
    public struct ManifestReference: Codable, Sendable {
        public let tag: String
        public let finalReference: Data
    }
    /// Explicit whitelist: future local resource-selector fields in SourceRecipe
    /// must not enter a remote content identity or archived PhotoKit identifiers.
    public struct ManifestOriginal: Codable, Sendable {
        public let role: ResourceRole
        public let uti: String
        public let originalFilename: String
        public let sha256: String
        public let sha1: String
        public let byteCount: Int64
        init(_ source: SourceResourceDescriptor) {
            role = source.role; uti = source.uti; originalFilename = source.originalFilename
            sha256 = source.sha256; sha1 = source.sha1; byteCount = source.byteCount
        }
    }
    public struct ArchiveRecipe: Codable, Sendable {
        public let schema: String
        public let kind: MediaKind
        public let isLivePhoto: Bool
        public let metadata: SourceAssetMetadata
        public let originals: [ManifestOriginal]
        public let resources: [ManifestResourceEntry]
    }
    public struct ManifestDocument: Codable, Sendable {
        public let recipe: ArchiveRecipe
        public let confirmedReferences: [ManifestReference]
    }
    public static func buildManifest(kind: MediaKind, isLivePhoto: Bool,
        metadata: SourceAssetMetadata, originals: [SourceResourceDescriptor],
        resources: [ManifestResourceEntry], receipts: [RemoteReceipt] = []
    ) throws -> (data: Data, associationHash: String) {
        guard !originals.isEmpty, originals.count <= 32, resources.count <= 255 else { throw CoreError.invalidContract }
        let recipe = ArchiveRecipe(schema: schemaVersion, kind: kind, isLivePhoto: isLivePhoto,
                                   metadata: metadata,
                                   originals: UploadPlanProducer.canonicalOriginals(originals).map(ManifestOriginal.init),
                                   resources: resources)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // Milliseconds since Unix epoch retain fractional external capture times;
        // metadata is private archive material, never diagnostic output.
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let stableData = try encoder.encode(recipe)
        let hash = SHA256.hash(data: stableData).map { String(format: "%02x", $0) }.joined()
        let requiredTags = Set(resources.map(\.tag))
        let references = receipts.filter { requiredTags.contains($0.tag) }.sorted { $0.tag < $1.tag }
            .map { ManifestReference(tag: $0.tag, finalReference: $0.opaqueReference) }
        let data = try encoder.encode(ManifestDocument(recipe: recipe, confirmedReferences: references))
        guard data.count <= 1_048_576 else { throw CoreError.invalidContract }
        return (data, hash)
    }
    /// Validate an untrusted remote manifest against its content-addressed recipe.
    /// This performs no media downloads and never accepts partial part sequences.
    static func validate(_ data: Data, expectedTag: String) throws -> ManifestDocument {
        guard !data.isEmpty, data.count <= 1_048_576 else { throw CoreError.invalidContract }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .millisecondsSince1970
        let document = try decoder.decode(ManifestDocument.self, from: data)
        let recipe = document.recipe
        guard recipe.schema == schemaVersion, !recipe.originals.isEmpty, recipe.originals.count <= 32,
              !recipe.resources.isEmpty, recipe.resources.count <= 255,
              document.confirmedReferences.count <= 255 else { throw CoreError.invalidContract }
        // Match the exact date encoding used when creating the archive recipe.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let association = ProviderSupport.fingerprint(try encoder.encode(recipe))
        guard try ContentIdentity.resource(role: .manifest, originals: [], associationHash: association).tag == expectedTag else { throw CoreError.invalidContract }
        let tags = Set(recipe.resources.map(\.tag))
        guard document.confirmedReferences.count == tags.count,
              Set(document.confirmedReferences.map(\.tag)) == tags,
              document.confirmedReferences.allSatisfy({ !$0.finalReference.isEmpty && $0.finalReference.count <= 4096 }) else { throw CoreError.invalidContract }
        for original in recipe.originals {
            _ = try ProviderSupport.hex(original.sha256, count: 32); _ = try ProviderSupport.hex(original.sha1, count: 20)
            guard original.byteCount > 0, original.role != .manifest, !original.uti.isEmpty,
                  !original.originalFilename.isEmpty, original.originalFilename.utf8.count <= 255 else { throw CoreError.invalidContract }
        }
        for entry in recipe.resources {
            let original = OriginalContent(sha256: entry.sha256, sha1: entry.sha1, byteCount: entry.byteCount,
                                           role: entry.role, partIndex: entry.partIndex, partCount: entry.partCount)
            _ = try ProviderSupport.hex(entry.sha256, count: 32); _ = try ProviderSupport.hex(entry.sha1, count: 20)
            guard entry.byteCount > 0, entry.role != .manifest,
                  try ContentIdentity.resource(role: entry.role, originals: [original]).tag == entry.tag else { throw CoreError.invalidContract }
            if entry.originalSha256 == nil {
                guard entry.partIndex == nil, entry.partCount == nil, entry.offset == nil,
                      recipe.originals.contains(where: { $0.role == entry.role && $0.sha256 == entry.sha256 && $0.sha1 == entry.sha1 && $0.byteCount == entry.byteCount }) else { throw CoreError.invalidContract }
            }
        }
        for original in recipe.originals {
            let parts = recipe.resources.filter { $0.originalSha256 == original.sha256 && $0.role == original.role }.sorted { ($0.partIndex ?? -1) < ($1.partIndex ?? -1) }
            if parts.isEmpty {
                guard recipe.resources.contains(where: { $0.sha256 == original.sha256 && $0.role == original.role && $0.originalSha256 == nil }) else { throw CoreError.invalidContract }
            } else {
                guard (2...255).contains(parts.count) else { throw CoreError.invalidContract }
                var offset: Int64 = 0
                for (index, part) in parts.enumerated() {
                    guard part.partIndex == index, part.partCount == parts.count, part.offset == offset,
                          part.byteCount <= 1_900_000_000, part.byteCount <= original.byteCount - offset else { throw CoreError.invalidContract }
                    offset += part.byteCount
                }
                guard offset == original.byteCount else { throw CoreError.invalidContract }
            }
        }
        guard recipe.resources.allSatisfy({ entry in entry.originalSha256.map { hash in recipe.originals.contains { $0.sha256 == hash && $0.role == entry.role } } ?? true }) else { throw CoreError.invalidContract }
        if recipe.isLivePhoto {
            guard recipe.originals.contains(where: { $0.role == .still }), recipe.originals.contains(where: { $0.role == .motion }) else { throw CoreError.invalidContract }
        }
        return document
    }

}
