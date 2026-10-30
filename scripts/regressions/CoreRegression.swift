import Foundation
import CSQLite
@testable import CloudifiedCore

func check(_ value: Bool, _ label: String) { precondition(value, label) }
enum ProbeError: Error { case rollback }
extension Ledger {
    func rolledBackSnapshot(jobID: UUID) throws {
        do {
            try transaction {
                try db.execute("UPDATE jobs SET state='confirmed' WHERE id=?", [jobID.sql])
                _ = try snapshot()
                throw ProbeError.rollback
            }
        } catch ProbeError.rollback {}
    }
    func logBudget() throws -> Int64 { try db.rows("SELECT byte_used AS n FROM log_budget WHERE id=1").first!.int("n") }
    func ageRoutine() throws { try db.execute("UPDATE events SET occurred=0 WHERE critical=0") }
    func truncateFailures() throws { try db.execute("DELETE FROM source_failures") }
}
struct Fixture {
    let ledger: Ledger
    let destination: Destination
    let asset: AssetIdentity
    let resource: ResourceRequirement
    let jobID: UUID
}
func fixture(_ root: URL, provider: Provider = .google) async throws -> Fixture {
    let ledger = try Ledger(databaseURL: root.appendingPathComponent(UUID().uuidString), version: "offline", revision: "unknown")
    let destination = try await ledger.selectDestination(Destination(provider: provider, verifiedFingerprint: String(repeating: "1", count: 64)))
    try await ledger.completeDestinationRecovery(destination.id)
    let scan = try await ledger.beginScan()
    let asset = try await ledger.registerAssets([AssetIdentity(localIdentifier: "host-boundary", generation: String(repeating: "a", count: 64), kind: .photo)], scanID: scan)[0]
    try await ledger.completeScan(scan)
    let resource = try ContentIdentity.resource(role: .still, originals: [OriginalContent(sha256: String(repeating: "b", count: 64), sha1: String(repeating: "c", count: 40), byteCount: 3, role: .still)])
    let job = try await ledger.enqueue(assetID: asset.id, destinationID: destination.id, plan: ContentIdentity.plan(policyVersion: "host-boundary", resources: [resource]))
    return Fixture(ledger: ledger, destination: destination, asset: asset, resource: resource, jobID: job)
}
func start(_ f: Fixture, now: Date = Date()) async throws -> JobRecord {
    let run = UUID()
    let job = try await f.ledger.claimNext(destinationID: f.destination.id, runID: run, now: now)!
    try await f.ledger.applyPresence(.verifiedAbsent, jobID: job.id, resourceID: f.resource.id, runID: run)
    _ = try await f.ledger.finishChecks(jobID: job.id, runID: run)
    return try await f.ledger.beginAttempt(jobID: job.id, runID: run)
}
@main struct CoreRegression {
    static func main() async throws {
        print("SQLite runtime: \(String(cString: sqlite3_libversion()))")
        try await authenticationRegression()
        backgroundCompletionRegression()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await albumExclusionRegression(root)
        try await albumMigrationRegression(root)
        try manifestBoundaryChecks()
        try await googleRemoteIndexChecks(root: root)
        try await googleReconciliationLimitChecks(root: root)
        try await receiptRecoveryChecks(root: root)
        try await diagnosticRootChecks(root: root)
        try await secondPassChecks(root: root)
        let limited = try await fixture(root, provider: .telegram)
        let delay = Date().addingTimeInterval(120)
        let limit = SafeFailure(.rateLimit, domain: .tdlib, code: 429, cause: .serverRateLimit)
        try await limited.ledger.blockDestination(limited.destination.id, failure: limit, resumeAt: delay)
        let healthy = try await limited.ledger.selectDestination(Destination(provider: .google, verifiedFingerprint: String(repeating: "2", count: 64)))
        try await limited.ledger.completeDestinationRecovery(healthy.id)
        check(try await limited.ledger.canRun(healthy.id), "Telegram account gate blocked Google")
        let limitedState = try await limited.ledger.snapshot().providers[1]
        check(limitedState.blockedReason == limit && abs((limitedState.resumeAt ?? .distantPast).timeIntervalSince(delay)) < 0.001 && !limitedState.recoveryComplete,
            "recovery-time rate limit lost its durable account gate")
        check(try await limited.ledger.nextWake(destinationID: limited.destination.id).map { abs($0.timeIntervalSince(delay)) < 0.001 } == true,
            "incomplete recovery hid account retry deadline")
        check(try await limited.ledger.claimNext(destinationID: limited.destination.id, runID: UUID(), now: delay.addingTimeInterval(1)) == nil,
            "time alone admitted work before native recovery")
        try await limited.ledger.completeDestinationRecovery(limited.destination.id)
        check(try await limited.ledger.claimNext(destinationID: limited.destination.id, runID: UUID(), now: delay.addingTimeInterval(1)) != nil,
            "verified recovery never released expired account wait")
        let beforeFlood = Date()
        do {
            _ = try await NativeRequestHarness(.tdlibError(code: 420, message: "FLOOD_WAIT_120")).getMe()
            preconditionFailure("getMe swallowed native flood wait")
        } catch let rejection as TDLibRequestRejection {
            check(rejection.failure.category == .rateLimit && (rejection.retryAfter?.timeIntervalSince(beforeFlood) ?? 0) >= 120,
                "getMe dropped the original account retry deadline")
        }
        let forbidden = TDLibClient.classify(TDLibError.tdlibError(code: 403, message: "forbidden fixture"))
        check(forbidden.category == .accessDenied && FailureExplanation.destinationAttention(forbidden) == .account,
            "forbidden Telegram request became a per-file format failure")
        let expired = SafeFailure(.authentication, domain: .google, code: 401, cause: .loginRequired)
        check(FailureExplanation.destinationAttention(expired) == .signIn && ProviderCardState.Attention.signIn.actionTitle == "Sign in again",
            "expired session lacks direct sign-in action")
        check(FailureExplanation.destinationAttention(limit) == .rateLimit && ProviderCardState.Attention.rateLimit.actionTitle == nil,
            "Telegram limit incorrectly offers login as cure")
        check(FailureExplanation.destinationMessage(limit, provider: .telegram, resumeAt: delay).contains("retry no earlier than"),
            "known server delay not explained")
        check(FailureExplanation.destinationMessage(limit, provider: .telegram, resumeAt: nil).contains("without giving a retry time"),
            "unknown delay fabricated retry date")
        check(FailureExplanation.destinationAttention(SafeFailure(.connectivity, domain: .tdlib, cause: .offline)) == nil &&
              FailureExplanation.destinationAttention(SafeFailure(.reconciliation, domain: .tdlib, cause: .pendingSendUnmatched)) == nil,
            "file/network failure mislabeled account problem")
        check(FailureExplanation.destinationAttention(SafeFailure(.authentication, domain: .tdlib, cause: .initializationFailed)) == .connection,
            "local connection failure mislabeled account problem")
        check(FailureExplanation.destinationAttention(SafeFailure(.accessDenied, domain: .photos, cause: .permissionDenied)) == nil,
            "Photos permission mislabeled account problem")
        print("PASS actual account waits: durable deadline survives incomplete recovery; native recovery still required; sign-in/rate/network remedies distinguished")
        try await providerEnableChecks(root: root)
        try await googleSubmissionChecks(root: root)
        let f = try await fixture(root), ledger = f.ledger
        _ = try await ledger.snapshot()
        let baseline = await ledger.snapshotPerformance()
        for _ in 0..<50 {
            try await ledger.appendEvent(.hashing, context: EventContext(origin: .source), decision: .proceed)
            _ = try await ledger.snapshot()
        }
        try await ledger.unblockDestination(f.destination.id)
        try await ledger.completeDestinationRecovery(f.destination.id)
        _ = try await ledger.snapshot()
        let after = await ledger.snapshotPerformance()
        check(after.computed == baseline.computed && after.reused >= baseline.reused + 50, "diagnostics recomputed counts")
        try await ledger.recordSourceFailure(assetID: f.asset.id, destinationIDs: [f.destination.id], error: SafeFailure(.sourceUnavailable, domain: .photos, cause: .sourceMissing), permanent: true)
        check(try await ledger.snapshot().providers[0].photos?.failed == 1, "source failure cache stale")
        try await ledger.truncateFailures()
        check(try await ledger.snapshot().providers[0].photos?.failed == 0, "whole-table DELETE missed cache invalidation")
        try await ledger.rolledBackSnapshot(jobID: f.jobID)
        check(try await ledger.snapshot().providers[0].confirmed == 0, "rolled-back count escaped cache")
        try await ledger.confirm(RemoteReceipt(destinationID: f.destination.id, tag: f.resource.tag, opaqueReference: Data([1]), kind: .uploaded), jobID: f.jobID, resourceID: f.resource.id)
        check(try await ledger.snapshot().providers[0].confirmed == 1, "confirmation cache stale")
        print("PASS actual snapshot cache: 50 diagnostic-only cache hits, source failure, truncate, rollback and confirmation invalidation")
        let plan = try await ledger.job(f.jobID).plan
        check(try await ledger.hasEnqueuedPlan(assetID: f.asset.id, destinationID: f.destination.id, coverageHash: plan.coverageHash), "matching plan missed")
        check(try await !ledger.hasEnqueuedPlan(assetID: f.asset.id, destinationID: f.destination.id, coverageHash: String(repeating: "f", count: 64)), "changed plan skipped")
        try await ledger.recordSourceFailure(assetID: f.asset.id, destinationIDs: [f.destination.id], error: SafeFailure(.timeout, domain: .photos, cause: .deadlineExceeded), permanent: false)
        check(try await !ledger.hasEnqueuedPlan(assetID: f.asset.id, destinationID: f.destination.id, coverageHash: plan.coverageHash), "source failure hidden by plan shortcut")
        try await ledger.truncateFailures()
        let retrySource = try await fixture(root)
        try await retrySource.ledger.recordSourceFailure(assetID: retrySource.asset.id, destinationIDs: [retrySource.destination.id], error: SafeFailure(.timeout, domain: .photos, cause: .deadlineExceeded), permanent: false)
        check(try await retrySource.ledger.hasRetryableSourceFailures(), "unchanged scan hides transient source failure")
        try await retrySource.ledger.setEnabled(retrySource.destination.id, false)
        check(try await !retrySource.ledger.hasRetryableSourceFailures(), "disabled source failure forces replan")
        try await retrySource.ledger.setEnabled(retrySource.destination.id, true)
        try await retrySource.ledger.confirm(RemoteReceipt(destinationID: retrySource.destination.id, tag: retrySource.resource.tag, opaqueReference: Data([1]), kind: .uploaded), jobID: retrySource.jobID, resourceID: retrySource.resource.id)
        check(try await !retrySource.ledger.hasRetryableSourceFailures(), "confirmed work forces replan")
        print("PASS actual transient-source cursor invalidation: retryable work revisited; disabled and confirmed work excluded")
        print("PASS actual planning lookup: exact alias/coverage required; changed plans and source failures cannot be skipped")
        let priorityFailure = SafeFailure(.transfer, domain: .google, cause: .providerRejected)
        try await ledger.appendEvent(.failure, context: EventContext(origin: .google), decision: .wait, severity: .error, failure: priorityFailure)
        _ = try await ledger.pruneDiagnostics(byteBudget: 2_000)
        check(try await ledger.logBudget() <= 2_000, "diagnostic byte budget exceeded")
        let retained = try await ledger.logPage(limit: 200)
        check(retained.events.contains { $0.failure == priorityFailure }, "routine logs displaced failure")
        try await ledger.ageRoutine()
        _ = try await ledger.pruneDiagnostics()
        check(try await ledger.snapshot().providers[0].confirmed == 1, "pruning changed receipt-backed counts")
        print("PASS actual diagnostic pruning: routine-first byte/age bounds, retained error, durable receipts unaffected")
        let retry = try await fixture(root), now = Date()
        for attempt in 1...3 {
            let job = try await start(retry, now: now.addingTimeInterval(Double(attempt) * 1_000))
            check(job.attempts == attempt, "attempt budget changed")
            try await retry.ledger.failAttempt(jobID: job.id, failure: UploadFailure(SafeFailure(.timeout, domain: .google, cause: .deadlineExceeded), disposition: .retryable, acceptance: .definitelyNotAccepted), now: now)
            let failed = try await retry.ledger.job(job.id)
            if attempt < 3 {
                let delay = failed.retryAt!.timeIntervalSince(now), base = attempt == 1 ? 30.0 : 120.0
                check(delay >= base * 0.8 && delay <= base * 1.2, "incorrect transient backoff")
            } else { check(failed.state == .failed, "more than three automatic attempts") }
        }
        let waiting = try await fixture(root)
        _ = try await start(waiting)
        try await waiting.ledger.failAttempt(jobID: waiting.jobID, failure: UploadFailure(SafeFailure(.connectivity, domain: .google, cause: .offline), disposition: .waiting, acceptance: .definitelyNotAccepted, didStartTransfer: false))
        let resumed = try await start(waiting, now: Date().addingTimeInterval(1_000))
        check(resumed.attempts == 1, "pre-send network wait burned attempt")
        print("PASS actual retries: jittered 30/120s, three-attempt cap, pre-send suspension resumes same logical attempt")
        let pair = try await fixture(root)
        for failure in 1...3 {
            let run = UUID()
            _ = try await pair.ledger.claimNext(destinationID: pair.destination.id, runID: run, now: Date().addingTimeInterval(1_000))
            try await pair.ledger.applyPresence(.unknown(SafeFailure(.reconciliation, domain: .google, cause: .pairingUnverified)), jobID: pair.jobID, resourceID: pair.resource.id, runID: run)
            let deadline = try await pair.ledger.nextWake(destinationID: pair.destination.id)
            try await pair.ledger.wakeWaiting(destinationID: pair.destination.id)
            try await pair.ledger.unblockDestination(pair.destination.id)
            check(try await pair.ledger.job(pair.jobID).state == .waiting, "automatic recovery re-polled incompatible pair")
            if failure < 3 {
                let expected = failure == 1 ? 60.0 : 300.0
                check(deadline.map { abs($0.timeIntervalSinceNow - expected) < 2 } == true, "sparse pairing deadline lost")
            } else { check(deadline == nil, "pairing timer persisted beyond bounded rechecks") }
        }
        try await pair.ledger.explicitRetry(jobID: pair.jobID)
        check(try await pair.ledger.claimNext(destinationID: pair.destination.id, runID: UUID()) != nil, "explicit pair retry lost")
        print("PASS actual Live Photo wait: sparse 60/300s rechecks then user action, generic wakes do not bypass deadlines, explicit retry remains possible")
        let held = try await fixture(root, provider: .telegram)
        let heldJob = try await start(held), transfer = UUID(), fileID = UUID()
        let files = try FileLeaseStore(root: root.appendingPathComponent("held"), ledger: held.ledger)
        let reserve = try await held.ledger.reserveStorage(bytes: 3, availableBytes: 2_000_000_000, transportOverhead: 0)
        let ownership = try await files.beginExport(fileID: fileID)
        try Data([1,2,3]).write(to: ownership.publishedURL)
        let leased = try await files.registerPublished(fileID: fileID, byteCount: 3, reservationID: reserve.id, reexportable: true)
        try await files.endExport(ownership)
        try await files.hold(files: [leased], transferID: transfer, job: heldJob, resourceID: held.resource.id)
        try await files.release(leased)
        _ = try await held.ledger.snapshot()
        try await held.ledger.saveProviderCheckpoint(ProviderCheckpoint(destinationID: held.destination.id,
            tag: held.resource.tag, transferID: transfer, jobID: heldJob.id, phase: .uncertain, inputsTerminal: false, payload: Data([1])))
        let protected = try await held.ledger.snapshot().providers[1]
        check(protected.retainedTransfers == 1 && protected.protectedUnresolvedTransfers == 1, "retained inventory cache stale")
        try await files.transportFinished(transfer)
        check(try await held.ledger.snapshot().providers[1].retainedTransfers == 0, "terminal hold count stale")
        print("PASS actual protected inventory: transfer/checkpoint and terminal-release count invalidation")
        let epoch = try await ledger.beginRemoteIndex(destinationID: f.destination.id)
        let entries = (0..<100).map { RemoteIndexEntry(tag: String(format: "%064x", $0), reference: Data([1])) }
        try await ledger.addRemoteIndex(destinationID: f.destination.id, epoch: epoch, entries: entries)
        check(try await !ledger.remoteIndex(destinationID: f.destination.id, epoch: epoch, tag: entries[0].tag).complete, "partial index claimed completeness")
        do { try await ledger.addRemoteIndex(destinationID: f.destination.id, epoch: epoch, entries: entries + [entries[0]]); preconditionFailure("oversized page admitted") } catch {}
        try await ledger.finishRemoteIndex(destinationID: f.destination.id, epoch: epoch)
        check(try await ledger.remoteIndex(destinationID: f.destination.id, epoch: epoch, tag: entries[0].tag).complete, "index completion lost")
        print("PASS actual remote index: bounded 100-entry page, 101 rejected, absence requires finished epoch")
        try credentialKeyChecks()
        activeBackupRequestChecks()
        try await diagnosticPrivacyChecks(root: root)
        try await localResetChecks(root: root)
        try await nativeProtocolChecks()
        try await censusChecks(root: root)
        try await laneChecks(root: root)
        try await admissionFailureChecks(root: root)
        try await auditBoundaryChecks(root: root)
        try await networkPolicyChecks()
        try await ownedRecoveryChecks(root: root)
        try await telegramSettlementChecks(root: root)
        awakeEligibilityChecks()
        issueIdentificationChecks()
        presentationChecks()
        await resolutionChecks()
        try await issueMetadataChecks(root: root)
        try await cleanupChecks(root: root)
    }
}
