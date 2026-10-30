import Foundation
import CloudifiedCore

func updateRoutingChecks() async throws {
    func file(_ id: Int32, terminal: Bool = false) -> TDLibResponse {
        TDLibResponse(fields: ["@type": .string("updateFile"), "file": .object(["id": .integer(Int64(id)),
            "local": .object(["is_downloading_active": .boolean(false), "is_downloading_completed": .boolean(false)]),
            "remote": .object(["is_uploading_active": .boolean(!terminal), "is_uploading_completed": .boolean(terminal),
                "uploaded_size": .integer(terminal ? 1 : 0)])])])
    }
    func message(_ chat: Int64, _ type: String = "updateNewMessage") -> TDLibResponse {
        TDLibResponse(fields: ["@type": .string(type), "message": .object(["chat_id": .integer(chat)])])
    }
    let old = UpdateRoutingHarness();await old.configure(-100,[9]);let oldStream = await old.subscribe(filtering:false)
    for _ in 0..<17 { await old.send(file(10,terminal:true)) }
    check(await old.failed(), "old irrelevant-file overflow was not reproduced")
    withExtendedLifetime(oldStream) {}
    let overloaded=TDLibError.capacityExceeded("Critical update overflow.")
    check(TDLibClient.classify(overloaded).cause == .nativeCapacityExceeded, "local overload mislabeled as server rejection")
    check(TDLibClient.nativeReason(overloaded) == .updateQueueCapacity, "capacity subtype lost")
    check(ProviderSupport.blocksDestination(overloaded,domain:.tdlib), "unreliable native input not fenced")
    check(TDLibClient.classify(TDLibError.capacityExceeded("Pending request capacity.")).cause == .operationBusy, "transient request capacity poisoned connection")
    let interest = TelegramUpdateInterest()
    interest.setChatID(-100);interest.setPendingFiles([])
    check(!interest.accepts(file(9)), "idle provider consumes unrelated file updates")
    interest.setPendingFiles([nil])
    check(interest.accepts(file(9, terminal: true)), "unknown owned ID lost potential terminal update")
    interest.setPendingFiles([9])
    check(interest.accepts(file(9, terminal: true)) && !interest.accepts(file(10)), "owned file relevance incorrect")
    check(interest.accepts(TDLibResponse(fields: ["@type": .string("updateFile")])), "malformed evidence silently dropped")
    let h = UpdateRoutingHarness();await h.configure(-100,[9],[-300]);let stream = await h.subscribe()
    for _ in 0..<1000 { await h.send(message(-200));await h.send(file(10,terminal:true)) }
    check(await !h.failed(), "irrelevant history/account burst poisoned native input")
    await h.send(message(-100,"updateMessageSendSucceeded"))
    await h.send(message(-100,"updateMessageSendFailed"))
    await h.send(file(9,terminal:true))
    await h.send(message(-300,"updateMessageSendSucceeded"))
    await h.send(message(-300,"updateMessageSendFailed"))
    var iterator=stream.makeAsyncIterator()
    var received:[String]=[]
    for _ in 0..<5 { received.append(try await iterator.next()!.type!) }
    check(received == ["updateMessageSendSucceeded","updateMessageSendFailed","updateFile","updateMessageSendSucceeded","updateMessageSendFailed"], "critical owned outcomes reordered or lost")
    for _ in 0..<17 { await h.send(message(-100,"updateMessageSendSucceeded")) }
    check(await h.failed(), "real critical overflow no longer fails closed")
    print("PASS actual native publish: old overflow reproduced, 2000 irrelevant events filtered before 16-slot queue; owned outcomes retained, real overflow protected")
}

private actor CapacityAdmissionAdapter: ProviderAdapter {
    nonisolated let provider: Provider
    var overloaded: Bool
    var admissions = 0
    init(_ provider: Provider, overloaded: Bool) { self.provider=provider; self.overloaded=overloaded }
    var canAcceptWork: Bool { get throws { admissions += 1; if overloaded { throw SafeFailure(.reconciliation,domain:.tdlib,cause:.nativeCapacityExceeded) };return true } }
    func healthy() { overloaded=false }
    func inspect(destination: Destination, resource: ResourceRequirement) -> RemotePresence {
        .present(RemoteReceipt(destinationID: destination.id,tag: resource.tag,opaqueReference: Data([7]),kind:.alreadyPresent))
    }
    func upload(job: JobRecord,resource: ResourceRequirement,files:[LeasedFile],transferID:UUID,
        progress:@escaping @Sendable(TransferProgress) async -> Void) -> UploadOutcome { preconditionFailure("present content sent") }
}
private struct CapacityNoExport: OriginalPreparer {
    func prepare(job:JobRecord,resource:ResourceRequirement,receipts:[RemoteReceipt]) throws -> [LeasedFile] { preconditionFailure("present content exported") }
}
func capacityAdmissionChecks(_ root: URL) async throws {
    let f=try await fixture(root,provider:.telegram)
    let google=try await f.ledger.selectDestination(Destination(provider:.google,verifiedFingerprint:String(repeating:"a",count:64)))
    try await f.ledger.completeDestinationRecovery(google.id)
    let capacity=SafeFailure(.reconciliation,domain:.tdlib,cause:.nativeCapacityExceeded)
    do { try await f.ledger.blockDestination(google.id,failure:capacity,resumeAt:nil);preconditionFailure("Telegram fault gated Google") }
    catch CoreError.invalidContract {}
    do { try await f.ledger.blockDestination(f.destination.id,failure:capacity,resumeAt:Date());preconditionFailure("fatal capacity gained timed unblock") }
    catch CoreError.invalidContract {}
    let job=try await f.ledger.job(f.jobID)
    _=try await f.ledger.enqueue(assetID:f.asset.id,destinationID:google.id,plan:job.plan)
    let files=try FileLeaseStore(root:root.appendingPathComponent(UUID().uuidString),ledger:f.ledger)
    let engine=BackupEngine(ledger:f.ledger,files:files)
    let tg=CapacityAdmissionAdapter(.telegram,overloaded:true),g=CapacityAdmissionAdapter(.google,overloaded:false)
    let result=try await engine.runReadyBatch(adapters:[tg,g],preparer:CapacityNoExport())
    check(result.first{$0.provider == .telegram}?.failure?.cause == .nativeCapacityExceeded,"native root error masked")
    check(result.first{$0.provider == .telegram}?.requiresRecovery == true,"fatal capacity did not request native recovery")
    check(try await f.ledger.snapshot().providers.first{$0.provider == .google}?.confirmed == 1,"Telegram capacity stopped Google")
    check(try await !f.ledger.canRun(f.destination.id),"broken stream not gated")
    _=try await engine.runReadyBatch(adapters:[tg,g],preparer:CapacityNoExport())
    check(await tg.admissions == 1,"same fatal stream repeatedly admitted")
    await tg.healthy();try await f.ledger.unblockDestination(f.destination.id)
    check(try await !f.ledger.canRun(f.destination.id),"unblock bypassed actual recovery")
    try await f.ledger.completeDestinationRecovery(f.destination.id)
    _=try await engine.runReadyBatch(adapters:[tg,g],preparer:CapacityNoExport())
    check(try await f.ledger.job(f.jobID).state == .confirmed,"verified recovery could not resume")
    print("PASS actual engine: native capacity gated once, Google independent, verified recovery resumes")
}
