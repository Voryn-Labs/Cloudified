import Foundation
import CloudifiedCore

func manifestBoundaryChecks() throws {
    let original = SourceResourceDescriptor(role: .still, uti: "public.heic", originalFilename: "fixture.heic",
        sha256: String(repeating: "b", count: 64), sha1: String(repeating: "c", count: 40), byteCount: 3)
    let metadata = SourceAssetMetadata(creationDate: Date(timeIntervalSince1970: 1_000), modificationDate: nil, pixelWidth: 1, pixelHeight: 1)
    let recipe = try SourceRecipe(assetLocalIdentifier: "host-manifest", generation: String(repeating: "a", count: 64),
        mediaKind: .photo, isLivePhoto: false, resources: [original], metadata: metadata)
    // Planning deliberately calculates identity before any remote receipt exists.
    let plan = try UploadPlanProducer.buildTelegramPlan(recipe: recipe)
    let media = try UploadPlanProducer.telegramMedia(recipe: recipe)
    let manifest = plan.resources.first { $0.role == .manifest }!
    let destination = UUID()
    let receipts = media.requirements.map { RemoteReceipt(destinationID: destination, tag: $0.tag, opaqueReference: Data([1]), kind: .uploaded) }
    let complete = try ArchiveManifestBuilder.buildManifest(kind: .photo, isLivePhoto: false, metadata: metadata,
        originals: [original], resources: media.entries, receipts: receipts)
    _ = try ArchiveManifestBuilder.validate(complete.data, expectedTag: manifest.tag)
    let planning = try ArchiveManifestBuilder.buildManifest(kind: .photo, isLivePhoto: false, metadata: metadata,
        originals: [original], resources: media.entries)
    check(planning.associationHash == complete.associationHash, "receipt availability changed archive identity")
    do { _ = try ArchiveManifestBuilder.validate(planning.data, expectedTag: manifest.tag); preconditionFailure("incomplete archive accepted remotely") }
    catch CoreError.invalidContract {}
    do {
        _ = try ArchiveManifestBuilder.buildManifest(kind: .photo, isLivePhoto: false, metadata: metadata,
            originals: [original], resources: media.entries, receipts: receipts + receipts)
        preconditionFailure("duplicate manifest references accepted")
    } catch CoreError.invalidContract {}
    do {
        _ = try ArchiveManifestBuilder.buildManifest(kind: .photo, isLivePhoto: false, metadata: metadata,
            originals: [original], resources: media.entries + media.entries, receipts: receipts)
        preconditionFailure("duplicate manifest entries accepted")
    } catch CoreError.invalidContract {}
    print("PASS actual Telegram planning without receipts, completed archive validation and duplicate-reference rejection")
}
