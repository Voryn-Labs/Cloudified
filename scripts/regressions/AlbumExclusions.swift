import Foundation
@testable import CloudifiedCore

func albumExclusionRegression(_ root: URL) async throws {
    let f = try await fixture(root)
    let receipt = RemoteReceipt(destinationID: f.destination.id, tag: f.resource.tag, opaqueReference: Data([1]), kind: .alreadyPresent)
    try await f.ledger.confirm(receipt, jobID: f.jobID, resourceID: f.resource.id)
    try await f.ledger.setAlbumExclusions([.google: ["private-album"]])
    check(try await !f.ledger.canRun(f.destination.id), "unpublished membership admitted sends")
    let rules = try await f.ledger.albumExclusionRules(.google)
    try await f.ledger.beginExclusionRefresh(.google, revision: rules.revision)
    try await f.ledger.stageExcludedAssets([f.asset.localIdentifier, f.asset.localIdentifier], provider: .google, revision: rules.revision)
    try await f.ledger.finishExclusionRefresh(.google, revision: rules.revision)
    let snapshot = try await f.ledger.snapshot().providers.first { $0.provider == .google }!
    check(snapshot.total == 0 && snapshot.excluded == 1 && snapshot.remaining == 0, "excluded counts mixed with remaining")
    check(try await f.ledger.receipts(for: f.jobID).count == 1, "exclusion erased remote evidence")
    try await f.ledger.setAlbumExclusions([:])
    let next = try await f.ledger.albumExclusionRules(.google)
    do { try await f.ledger.finishExclusionRefresh(.google, revision: rules.revision); preconditionFailure("stale membership published") }
    catch CoreError.staleMapping {}
    try await f.ledger.beginExclusionRefresh(.google, revision: next.revision)
    try await f.ledger.finishExclusionRefresh(.google, revision: next.revision)
    let restored = try await f.ledger.snapshot().providers.first { $0.provider == .google }!
    check(restored.total == 1 && restored.confirmed == 1 && restored.excluded == 0, "removing exclusion forgot confirmation")

    let alias = try await fixture(root)
    let scan = try await alias.ledger.beginScan()
    let second = try await alias.ledger.registerAssets([alias.asset, AssetIdentity(localIdentifier: "allowed-alias", generation: alias.asset.generation, kind: .photo)], scanID: scan)[1]
    try await alias.ledger.completeScan(scan)
    let job = try await alias.ledger.job(alias.jobID)
    let sameJob = try await alias.ledger.enqueue(assetID: second.id, destinationID: alias.destination.id, plan: job.plan)
    check(sameJob == alias.jobID, "fixture did not establish a shared content job")
    try await alias.ledger.setAlbumExclusions([.google: ["excluded-album"]])
    let revision = try await alias.ledger.albumExclusionRules(.google).revision
    try await alias.ledger.beginExclusionRefresh(.google, revision: revision)
    try await alias.ledger.stageExcludedAssets([alias.asset.localIdentifier], provider: .google, revision: revision)
    try await alias.ledger.finishExclusionRefresh(.google, revision: revision)
    let claimed = try await alias.ledger.claimNext(destinationID: alias.destination.id, runID: UUID())
    check(claimed?.asset.id == second.id, "excluded primary source trapped its eligible content alias")
    check(try await alias.ledger.exclusionReady(.telegram), "Google policy blocked unrelated Telegram eligibility")
    print("PASS album exclusion admission, atomic revision fencing, counts, receipts and eligible content aliases")
}

private extension Ledger {
    func simulateLegacySchema() throws -> URL {
        let path = try db.rows("PRAGMA database_list").first!.string("file")
        try db.transaction {
            for table in ["album_exclusions", "exclusion_state", "excluded_assets", "exclusion_build"] {
                try db.execute("DROP TABLE \(table)")
            }
            try db.execute("PRAGMA user_version=5")
        }
        return URL(fileURLWithPath: path)
    }
    func schemaVersionForRegression() throws -> Int64 {
        try db.rows("PRAGMA user_version").first!.int("user_version")
    }
}
func albumMigrationRegression(_ root: URL) async throws {
    let f = try await fixture(root)
    let receipt = RemoteReceipt(destinationID: f.destination.id, tag: f.resource.tag, opaqueReference: Data([7]), kind: .alreadyPresent)
    try await f.ledger.confirm(receipt, jobID: f.jobID, resourceID: f.resource.id)
    let url = try await f.ledger.simulateLegacySchema()
    let reopened = try Ledger(databaseURL: url, version: "0.8", revision: "unknown")
    check(try await reopened.schemaVersionForRegression() == 6, "schema fence not advanced")
    check(try await reopened.job(f.jobID).state == .confirmed, "migration reset a confirmed job")
    check(try await reopened.receipts(for: f.jobID).first?.opaqueReference == Data([7]), "migration lost receipt bytes")
    check(try await reopened.albumExclusionRules(.google).albumIDs.isEmpty, "migration invented exclusion rules")
    print("PASS actual v5-to-v6 reopen migration preserves confirmed jobs and exact receipt bytes")
}
