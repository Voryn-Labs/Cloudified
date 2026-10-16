import Foundation
import CloudifiedCore

/// Deterministic upload plan builder generating provider-specific plans via ContentIdentity.
public enum UploadPlanProducer {
    /// Builds the Google Photos upload plan adhering to the specified Live Photo fallback choice.
    public static func buildGooglePlan(
        recipe: SourceRecipe,
        livePhotoFallback: LivePhotoFallbackOption = .nativePair
    ) throws -> UploadPlan {
        try recipe.validate()
        var requirements: [ResourceRequirement] = []
        let policyVersion: String

        let selected: [SourceResourceDescriptor]
        if recipe.isLivePhoto {
            let hasStill = recipe.resources.contains { $0.role == .still }
            let hasMotion = recipe.resources.contains { $0.role == .motion }
            switch livePhotoFallback {
            case .nativePair:
                let stills = recipe.resources.filter { $0.role == .still }
                let motions = recipe.resources.filter { $0.role == .motion }
                guard stills.count == 1, motions.count == 1 else {
                    throw SafeFailure(.unsupportedOriginal, domain: .google, cause: .formatRejected)
                }
                requirements.append(try ContentIdentity.resource(role: .still, originals: [stills[0].originalContent, motions[0].originalContent]))
                policyVersion = "google-live-nativePair-v1"
                selected = recipe.resources.filter { $0.role != .still && $0.role != .motion }
            case .keyImageOnly:
                guard hasStill else { throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing) }
                policyVersion = "google-live-keyImageOnly-v1"
                selected = recipe.resources.filter { $0.role != .motion }
            case .motionVideoOnly:
                guard hasMotion else { throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing) }
                policyVersion = "google-live-motionVideoOnly-v1"
                selected = recipe.resources.filter { $0.role == .motion }
            case .bothSeparately:
                guard hasStill && hasMotion else { throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing) }
                policyVersion = "google-live-bothSeparately-v1"
                selected = recipe.resources
            }
        } else {
            policyVersion = recipe.mediaKind == .video ? "google-video-v1" : "google-photo-v1"
            selected = recipe.resources
        }
        for original in canonicalOriginals(selected) {
            requirements.append(try ContentIdentity.resource(role: original.role, originals: [original.originalContent]))
        }

        guard !requirements.isEmpty else {
            throw SafeFailure(.unsupportedOriginal, domain: .photos, cause: .formatRejected)
        }

        let plan = try ContentIdentity.plan(policyVersion: policyVersion, resources: uniqueRequirements(requirements))
        return plan
    }

    /// Builds the Telegram upload plan requiring every original resource/part plus archive manifest.
    public static func buildTelegramPlan(recipe: SourceRecipe) throws -> UploadPlan {
        try recipe.validate()
        let policyVersion = "telegram-archive-v2"
        let media = try telegramMedia(recipe: recipe)
        var requirements = media.requirements
        let manifestEntries = media.entries

        // Generate manifest association hash including full-original reconstruction descriptors
        let (_, associationHash) = try ArchiveManifestBuilder.buildManifest(
            kind: recipe.mediaKind,
            isLivePhoto: recipe.isLivePhoto,
            metadata: recipe.metadata,
            originals: recipe.resources,
            resources: manifestEntries
        )

        // Manifest resource requirement
        let manifestReq = try ContentIdentity.resource(
            role: .manifest,
            originals: [],
            associationHash: associationHash
        )
        requirements.append(manifestReq)

        let plan = try ContentIdentity.plan(policyVersion: policyVersion, resources: requirements)
        return plan
    }

    /// Shared recipe expansion keeps every parent-to-part binding, even when two
    /// different originals reuse an identical part and its single remote receipt.
    static func telegramMedia(recipe: SourceRecipe) throws ->
        (requirements: [ResourceRequirement], entries: [ArchiveManifestBuilder.ManifestResourceEntry]) {
        try recipe.validate()
        if recipe.isLivePhoto {
            guard recipe.resources.contains(where: { $0.role == .still }),
                  recipe.resources.contains(where: { $0.role == .motion }) else {
                throw SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing)
            }
        }
        var requirements: [ResourceRequirement] = []
        var manifestEntries: [ArchiveManifestBuilder.ManifestResourceEntry] = []

        for resDesc in canonicalOriginals(recipe.resources) {
            if let split = recipe.videoSplits.first(where: {
                $0.originalSha256 == resDesc.sha256 && $0.role == resDesc.role && $0.totalByteCount == resDesc.byteCount
            }), split.parts.count > 1 {
                // Multipart oversized original
                for part in split.parts {
                    let original = part.originalContent
                    let req = try ContentIdentity.resource(role: part.role, originals: [original])
                    requirements.append(req)
                    manifestEntries.append(.init(
                        role: part.role,
                        tag: req.tag,
                        sha256: part.sha256,
                        sha1: part.sha1,
                        byteCount: part.byteCount,
                        partIndex: part.partIndex,
                        partCount: part.partCount,
                        originalSha256: resDesc.sha256,
                        offset: part.offset
                    ))
                }
            } else {
                // An oversized component cannot silently bypass required splitting.
                guard resDesc.byteCount <= LosslessVideoPartSplitter.defaultTargetPartSize else {
                    throw SafeFailure(.unsupportedOriginal, domain: .tdlib, cause: .formatRejected)
                }
                // Standard non-split original resource
                let original = resDesc.originalContent
                let req = try ContentIdentity.resource(role: resDesc.role, originals: [original])
                requirements.append(req)
                manifestEntries.append(.init(
                    role: resDesc.role,
                    tag: req.tag,
                    sha256: resDesc.sha256,
                    sha1: resDesc.sha1,
                    byteCount: resDesc.byteCount
                ))
            }
        }

        // Multiple descriptors can contain the same bytes; archive every descriptor,
        // but create one remote obligation/reference for each identical content tag.
        requirements = uniqueRequirements(requirements)
        var seenEntries: Set<String> = []
        manifestEntries = manifestEntries.filter {
            seenEntries.insert("\($0.tag):\($0.originalSha256 ?? "whole"):\($0.offset ?? 0)").inserted
        }
        return (requirements, manifestEntries)


    }

    static func canonicalOriginals(_ originals: [SourceResourceDescriptor]) -> [SourceResourceDescriptor] {
        originals.sorted {
            ($0.role.rawValue, $0.sha256, $0.sha1, $0.byteCount, $0.uti, $0.originalFilename) <
            ($1.role.rawValue, $1.sha256, $1.sha1, $1.byteCount, $1.uti, $1.originalFilename)
        }
    }
    private static func uniqueRequirements(_ requirements: [ResourceRequirement]) -> [ResourceRequirement] {
        var seen: Set<String> = []
        return requirements.filter { seen.insert($0.tag).inserted }
    }
}
