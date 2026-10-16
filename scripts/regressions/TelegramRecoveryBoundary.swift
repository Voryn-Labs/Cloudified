import Foundation
import CloudifiedCore

actor NetworkPolicyBoundary {
    enum Authorization { case ready, uninitialized, waitTdlibParameters, closed, closing, uncertain }
    var authState: Authorization { .ready }
    private var calls: [String] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var hold = true
    private var reject = false
    func sendRequest(_ request: sending [String: Any], timeout: TimeInterval) async throws -> TDLibResponse {
        let type = (request["type"] as! [String: String])["@type"]!
        calls.append(type)
        if hold { hold = false; await withCheckedContinuation { gate = $0 } }
        if reject { reject = false; throw ProbeError.rollback }
        return TDLibResponse(fields: ["@type": .string("ok")])
    }
    func rejectNext() { reject = true }
    func holdNext() { hold = true }
    func started() -> Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
    func history() -> [String] { calls }
}
actor PolicyCompletion {
    private var done = false
    func finish() { done = true }
    func value() -> Bool { done }
}
func networkPolicyChecks() async throws {
    let boundary = NetworkPolicyBoundary(), policy = NetworkPolicyHarness(boundary), completion = PolicyCompletion()
    let pause = Task { try await policy.setNetworkPolicy(allowed: false, wifi: false) }
    while await !boundary.started() { await Task.yield() }
    let resume = Task {
        try await policy.setNetworkPolicy(allowed: true, wifi: true)
        await completion.finish()
    }
    while await policy.desired() != "networkTypeWiFi" { await Task.yield() }
    try await Task.sleep(for: .milliseconds(20))
    check(await !completion.value(), "resume returned before queued native network restoration")
    await boundary.release()
    try await pause.value; try await resume.value
    check(await boundary.history() == ["networkTypeNone", "networkTypeWiFi"], "network updates not serialized to latest desired gate")
    try await policy.setNetworkPolicy(allowed: true, wifi: true)
    check(await boundary.history().count == 2, "unchanged policy resent")
    await boundary.holdNext()
    let secondPause = Task { try await policy.setNetworkPolicy(allowed: false, wifi: false) }
    while await !boundary.started() { await Task.yield() }
    let secondCompletion = PolicyCompletion()
    let secondResume = Task {
        try await policy.setNetworkPolicy(allowed: true, wifi: true)
        await secondCompletion.finish()
    }
    while await policy.desired() != "networkTypeWiFi" { await Task.yield() }
    try await Task.sleep(for: .milliseconds(20))
    check(await !secondCompletion.value(), "cached Wi-Fi bypassed joining an in-flight network disable")
    await boundary.release()
    try await secondPause.value; try await secondResume.value
    check(await boundary.history() == ["networkTypeNone", "networkTypeWiFi", "networkTypeNone", "networkTypeWiFi"], "pause/resume left stale native policy")
    await boundary.holdNext()
    let cancelledCaller = Task { try await policy.setNetworkPolicy(allowed: false, wifi: false) }
    while await !boundary.started() { await Task.yield() }
    cancelledCaller.cancel()
    let joined = PolicyCompletion()
    let latest = Task { try await policy.setNetworkPolicy(allowed: true, wifi: true); await joined.finish() }
    while await policy.desired() != "networkTypeWiFi" { await Task.yield() }
    try await Task.sleep(for: .milliseconds(20))
    check(await !joined.value(), "cancelled caller orphaned its live policy operation")
    await boundary.release()
    try await cancelledCaller.value; try await latest.value
    await boundary.rejectNext()
    do { try await policy.setNetworkPolicy(allowed: false, wifi: false); preconditionFailure("native rejection ignored") }
    catch ProbeError.rollback { }
    try await policy.setNetworkPolicy(allowed: false, wifi: false)
    check(await boundary.history().suffix(2) == ["networkTypeNone", "networkTypeNone"], "failed network task poisoned future policy application")
    print("PASS actual TDLib policy: concurrent resume joins in-flight pause, latest gate acknowledged, unchanged gate suppressed")
}

actor OwnedRecoveryBoundary {
    let message: TDLibResponse?
    let local: Bool
    let looping: Bool
    let failed: Bool
    private var serverRequests = 0
    private var failedRequests = 0
    init(_ message: TDLibResponse?, local: Bool = false, looping: Bool = false, failed: Bool = false) {
        self.message = message; self.local = local; self.looping = looping; self.failed = failed
    }
    func failedSearches() -> Int { failedRequests }
    func searches() -> Int { serverRequests }
    func request(_ request: sending [String: Any], timeout: TimeInterval = 30) throws -> TDLibResponse {
        let method = request["@type"] as! String
        if method == "getMessage" {
            guard let message, request["message_id"] as? Int64 == message["id"]?.int64Value else {
                throw SafeFailure(.transfer, domain: .tdlib, code: 404, cause: .providerRejected)
            }
            return message
        }
        if method == "getFile" {
            let file = message!.object(forKey: "content")!.object(forKey: "document")!.object(forKey: "document")!
            precondition(request["file_id"] as? Int32 == file["id"]?.int32Value, "recovery used a stale native file ID")
            return TDLibResponse(fields: file.fields.merging(["@type":.string("file")]) {_,new in new})
        }
        if method == "getChatHistory" {
            return TDLibResponse(fields: ["@type": .string("messages"),
                "messages": .array(local ? [TDLibValue.object(message!.fields)] : [])])
        }
        precondition(method == "searchChatMessages" && request["query"] as? String != nil && timeout <= 5)
        let isFailed = (request["filter"] as? [String:String])?["@type"] == "searchMessagesFilterFailedToSend"
        if isFailed { precondition(request["query"] as? String == ""); failedRequests += 1 }
        else { serverRequests += 1 }
        return TDLibResponse(fields: ["@type": .string("foundChatMessages"),
            "messages": .array((isFailed ? (failed ? message : nil) : (failed ? nil : message)).map { [.object($0.fields)] } ?? []),
            "next_from_message_id": .integer(!isFailed && looping ? 50 : 0)])
    }
}
func ownedRecoveryChecks(root: URL) async throws {
    let tag = String(repeating: "a", count: 64), transfer = UUID()
    let input = TelegramInputFiles(stagingRoot: root)
    let expected = try input.url(transferID: transfer, filename: "original.heic").path
    func message(path: String, fileID: Int64 = 7) -> TDLibResponse {
        TDLibResponse(fields: ["@type": .string("message"), "id": .integer(100), "chat_id": .integer(-100),
            "is_channel_post": .boolean(true), "content": .object(["@type": .string("messageDocument"),
                "caption": .object(["text": .string(ContentIdentity.version + ":" + tag)]),
                "document": .object(["file_name": .string("original.heic"), "document": .object([
                    "id": .integer(fileID), "size": .integer(3), "local": .object(["path": .string(path)]),
                    "remote": .object(["unique_id": .string("owned"), "is_uploading_completed": .boolean(true),
                                       "is_uploading_active": .boolean(false)])])])])])
    }
    let checkpoint = ProviderCheckpoint(destinationID: UUID(), tag: tag, transferID: transfer, jobID: UUID(),
        phase: .uncertain, inputsTerminal: false, payload: Data())
    for local in [true, false] {
        let boundary = OwnedRecoveryBoundary(message(path: expected), local: local)
        let harness = OwnedRecoveryHarness(input, boundary)
        check(try await harness.lookup(checkpoint, fileID: 7) != nil, "owned send not recovered")
        check(await boundary.searches() == (local ? 0 : 1), "local hit searched server or local miss never searched server")
    }
    let matcher = OwnedRecoveryHarness(input, OwnedRecoveryBoundary(nil))
    check(try await matcher.match(checkpoint, message: message(path: expected, fileID: 99)) == 1,
        "restored update with new native IDs not matched to transfer")
    check(try await matcher.match(checkpoint, message: message(path: expected + "-other"), oldMessageID: 50) == nil,
        "stale persisted message ID settled a foreign input")
    let foreign = OwnedRecoveryHarness(input, OwnedRecoveryBoundary(message(path: expected + "-other")))
    check(try await foreign.lookup(checkpoint, fileID: 7) == nil, "same caption settled a different reader")
    let missing = OwnedRecoveryHarness(input, OwnedRecoveryBoundary(nil))
    check(try await missing.lookup(checkpoint, fileID: 7) == nil, "search miss fabricated presence")
    let base = "/var/mobile/Containers/Data/Application/"
    let suffix = "/Library/Application Support/Cloudified/telegram-inputs/\(transfer.uuidString)/original.heic"
    let old = base + UUID().uuidString + suffix, new = "/private" + base + UUID().uuidString + suffix
    check(TelegramInputFiles.matchesOwnedPath(old, expected: new), "valid container relocation ignored")
    check(!TelegramInputFiles.matchesOwnedPath(old + "-other", expected: new), "different filename accepted")
    check(!TelegramInputFiles.matchesOwnedPath(old.replacingOccurrences(of: transfer.uuidString, with: UUID().uuidString), expected: new), "different transfer accepted")
    check(try OwnedRecoveryHarness.matchesOwnedMessage(message(path: old), chatID: -100, tag: tag,
        expectedPath: new, byteCount: 3), "valid relocated native document not accepted")
    check(try OwnedRecoveryHarness.matchesOwnedMessage(message(path: old, fileID: 88), chatID: -100, tag: tag,
        expectedPath: new, byteCount: 3), "restored send with reassigned native file ID lost its unique transfer identity")
    check(try !OwnedRecoveryHarness.matchesOwnedMessage(message(path: expected), chatID: -101, tag: tag,
        expectedPath: expected, byteCount: 3), "different destination accepted")
    check(try !OwnedRecoveryHarness.matchesOwnedMessage(message(path: expected), chatID: -100, tag: String(repeating: "b", count: 64),
        expectedPath: expected, byteCount: 3), "different content tag accepted")
    let failed = OwnedRecoveryBoundary(message(path: expected), failed: true)
    check(try await OwnedRecoveryHarness(input, failed).lookup(checkpoint, fileID: 999) != nil,
        "old failed send outside recent history not recovered")
    let failedCount = await failed.failedSearches(), serverCount = await failed.searches()
    check(failedCount == 1 && serverCount == 0, "failed search not used before server lookup")
    check(!TelegramInputFiles.matchesOwnedPath(old.replacingOccurrences(of: "Application/", with: "Other/"), expected: new), "foreign namespace accepted")
    check(!TelegramInputFiles.matchesOwnedPath(old.replacingOccurrences(of: "/Library/", with: "/../Library/"), expected: new), "traversal accepted")
    let looping = OwnedRecoveryBoundary(nil, looping: true)
    do {
        _ = try await OwnedRecoveryHarness(input, looping).lookup(checkpoint, fileID: 7)
        preconditionFailure("repeated server cursor not fenced")
    } catch let failure as SafeFailure { check(failure.cause == .incompleteHistory, "cursor error lost") }
    check(await looping.searches() == 2, "unbounded repeated server cursor")
    print("PASS actual Telegram recovery: failed/local/server positives, reassigned native IDs, strict transfer paths, unknown misses and bounded cursor loops")
}

func awakeEligibilityChecks() {
    check(AppRuntime.isHosted(environment: ["LC_HOME_PATH": "/host"]), "LiveContainer runtime not recognized")
    check(!AppRuntime.isHosted(environment: [:]) && !AppRuntime.isHosted(environment: ["LC_HOME_PATH": ""]),
        "installed app incorrectly lost background capability")
    check(!AppRuntime.isHosted(environment: ["HOME": "/installed", "LC_OTHER": "1"]),
        "unrelated environment variables must not select hosted fallback")
    var state = DashboardViewState(overallState: .waiting(reason: "Verification"))
    state.canPause = true
    state.googleStatus = ProviderCardState(name: "Google Photos", isConnected: true, remainingCount: 0)
    state.telegramStatus = ProviderCardState(name: "Telegram", isConnected: true, remainingCount: 2)
    state.telegramStatus.protectedUnresolvedCount = 2
    check(!state.keepAwakeAllowed && state.summaryTitle == "Awaiting verification", "protected-only backlog keeps display awake or claims active backup")
    state.telegramStatus.remainingCount = 3
    check(state.keepAwakeAllowed, "independent ready work incorrectly disables Keep Awake")
    state.controlActivity = "Pausing…"
    check(!state.keepAwakeAllowed && state.summaryTitle == "Pausing…", "transition not visible or still keeps display awake")
    state.controlActivity = nil; state.overallState = .paused
    check(!state.keepAwakeAllowed, "paused backup keeps display awake")
    state.overallState = .scanning
    check(state.keepAwakeAllowed, "active scan allowed to lock")
    print("PASS actual awake model: protected-only wait releases display, healthy work and scan retained, pause/transition explicit")
}

func telegramSettlementChecks(root: URL) async throws {
    for scenario in 0...3 {
        let f = try await fixture(root, provider: .telegram), job = try await start(f)
        let files = try FileLeaseStore(root: root.appendingPathComponent(UUID().uuidString), ledger: f.ledger)
        let transfer = UUID(), fileID = UUID()
        let reserve = try await f.ledger.reserveStorage(bytes: 3, availableBytes: 2_000_000_000, transportOverhead: 0)
        let ownership = try await files.beginExport(fileID: fileID)
        try Data([1,2,3]).write(to: ownership.publishedURL)
        let leased = try await files.registerPublished(fileID: fileID, byteCount: 3, reservationID: reserve.id, reexportable: true)
        try await files.endExport(ownership)
        try await files.hold(files: [leased], transferID: transfer, job: job, resourceID: f.resource.id)
        let inputs = TelegramInputFiles(stagingRoot: files.root)
        let path = try inputs.create(transferID: transfer, input: leased, filename: "original.heic").path
        try await files.release(leased)
        let checkpoint = ProviderCheckpoint(destinationID: f.destination.id, tag: f.resource.tag, transferID: transfer,
            jobID: job.id, phase: .uncertain, inputsTerminal: false, payload: Data())
        let failed = scenario == 0 || scenario == 3
        var fields: [String:TDLibValue] = ["@type":.string("message"), "id":.integer(100), "chat_id":.integer(-100),
            "is_channel_post":.boolean(true), "content":.object(["@type":.string("messageDocument"),
                "caption":.object(["text":.string(ContentIdentity.version + ":" + f.resource.tag)]),
                "document":.object(["file_name":.string("original.heic"), "document":.object([
                    "id":.integer(99), "size":.integer(3), "local":.object(["path":.string(scenario == 2 ? path + "-foreign" : path)]),
                    "remote":.object(["unique_id":.string("recovered"), "is_uploading_completed":.boolean(!failed),
                        "is_uploading_active":.boolean(scenario == 3)])])])])]
        if failed { fields["sending_state"] = .object(["@type":.string("messageSendingStateFailed"),
            "error":.object(["code":.integer(400), "message":.string("Message is too old to be re-sent automatically")])]) }
        let boundary = OwnedRecoveryBoundary(TDLibResponse(fields: fields), failed: failed)
        let harness = TelegramSettlementHarness(boundary, f.ledger, files)
        try await harness.install(checkpoint)
        try await harness.run(f.destination)
        let actual = try await f.ledger.providerCheckpoint(destinationID: f.destination.id, tag: f.resource.tag)!
        let retained = try await f.ledger.hasRetainedTransfers(jobID: job.id)
        if scenario == 0 {
            check(actual.phase == .rejected && actual.inputsTerminal && !retained, "restored native rejection did not settle hold")
            let recovered = try await f.ledger.job(job.id)
            check(recovered.state == .reconciling && actual.failure?.error.cause == .interrupted,
                "expired outbox was mislabeled unsupported or not retryable")
            check(recovered.attempts == 1, "recovery itself consumed an extra logical attempt")
            check(try await f.ledger.claimNext(destinationID: f.destination.id, runID: UUID(), now: Date().addingTimeInterval(40)) != nil,
                "settled rejection remained trapped instead of fresh presence check")
        } else if scenario == 1 {
            check(actual.phase == .confirmed && actual.inputsTerminal && !retained, "completed owned send did not settle hold")
            check(try await f.ledger.job(job.id).state == .confirmed, "actual receipt did not confirm job")
        } else {
            check(!actual.inputsTerminal && retained, "unknown/active native ownership erased")
            check(try await f.ledger.job(job.id).state != .confirmed, "unknown send fabricated Saved")
            check(try await f.ledger.snapshot().providers[1].recoveryComplete, "one protected reader blocked destination recovery")
        }
        check(FileManager.default.fileExists(atPath: path) == retained, "input cleanup disagrees with native ownership")
    }
    print("PASS actual Telegram settlement: restored failed send retries after terminal proof, completed receipt releases hold, foreign and active readers remain protected")
}
