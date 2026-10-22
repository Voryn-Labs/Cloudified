import Foundation
import CloudifiedCore

/// One native client and one bounded update consumer. Eight uncertain sends may
/// retain ownership without preventing unrelated ready assets from proceeding.
/// Three logical attempts remain exclusively owned by BackupEngine/Ledger.
struct TelegramNativeTransferStatus: Sendable {
    enum Activity: Sendable, Equatable { case uploading, awaitingAcknowledgement, waitingForConnection, uncertain }
    let transferID: UUID
    let destinationID: UUID
    let jobID: UUID
    let resourceTag: String
    let uploadedBytes: Int64
    let expectedBytes: Int64
    let activity: Activity
}
actor TelegramProviderAdapter: ProviderAdapter {
    nonisolated let provider = Provider.telegram
    nonisolated let recoveryEvents: AsyncStream<Void>
    nonisolated let statusEvents: AsyncStream<Void>
    private let statusContinuation: AsyncStream<Void>.Continuation
    private let eventContinuation: AsyncStream<Void>.Continuation
    private struct Scope: Codable, Equatable { let version: Int; let userID: Int64; let chatID: Int64 }
    private struct State: Codable, Sendable {
        let chatID: Int64
        let sendingID: Int32
        let byteCount: Int64
        let filename: String
        var temporaryID: Int64?
        var fileID: Int32?
        var reference: TelegramDocumentReference?
    }
    private enum Resolution: Sendable {
        case confirmed(TelegramDocumentReference)
        case rejected(SafeFailure, TimeInterval?)
        case uncertain(SafeFailure)
    }
    private struct Pending {
        var checkpoint: ProviderCheckpoint
        var state: State
        var resolution: Resolution?
        var waiter: CheckedContinuation<Resolution, Never>?
        var deadline: Task<Void, Never>?
        var pump: ProviderProgressPump?
        var uploadedBytes: Int64 = 0
        var nativeActive = false
        var lastByteAdvance = ProcessInfo.processInfo.systemUptime
        var quarantined = false
        var inputInventoried = false
        var lastRecoveryLookup: TimeInterval?
    }
    private let client: TDLibClient
    private let ledger: Ledger
    private let files: FileLeaseStore
    private let inputFiles: TelegramInputFiles
    private var mapped: Destination?
    private var scope: Scope?
    private var consumer: Task<Void, Never>?
    private var streamFailure: SafeFailure?
    private var pending: [Int32: Pending] = [:]
    private var nextSendingID: Int32 = 1
    private var busy = false
    private var epoch: UUID?
    private struct Census {
        let destinationID: UUID
        let chatID: Int64
        let generation: UInt64
        let epoch: UUID
        var cursor: Int64 = 0
        var read = 0, pages = 0
        var finished = false
        var advancedAt = ProcessInfo.processInfo.systemUptime
    }
    private var census: Census?
    private var protocolRestarts = 0
    // Retain positive candidates across gaps; each is validated with getMessage.
    // Only a complete uninterrupted census can establish absence.
    private var absenceCurrent = false
    private var lastConnectionState: String?
    private var historyRevision: UInt64 = 0
    private var scanning = false
    /// Channel files read by the census in progress. Telegram's total is only
    /// approximate, so no fraction is derived from it.
    private var censusRead: Int?

    init(client: TDLibClient, ledger: Ledger, files: FileLeaseStore) {
        self.client = client; self.ledger = ledger; self.files = files
        let events = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        recoveryEvents = events.stream; eventContinuation = events.continuation
        let status = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        statusEvents = status.stream; statusContinuation = status.continuation
        inputFiles = TelegramInputFiles(stagingRoot: files.root)
    }
    /// Real retained native work remains visible after the Core worker stops
    /// waiting. The UI merges by transfer/job identity, never inventing Saved.
    var canAcceptWork: Bool { get async { pending.count < 8 && streamFailure == nil } }
    /// Includes potential native readers only after their exact input path and
    /// durable hold have been protected, even when the message ID is unmatched.
    func inventoriedInputTransfers() -> Set<UUID> {
        Set(pending.values.filter { $0.inputInventoried }
            .map { $0.checkpoint.transferID })
    }
    func channelCheckProgress() -> Int? { censusRead }
    /// Once per process, retire a broken native session without deleting its
    /// database, staged originals, checkpoints or transport holds.
    func restartAfterProtocolFailure() async throws {
        guard !busy, protocolRestarts == 0, await client.restartableProtocolFailure else {
            if let streamFailure { throw streamFailure }; throw CoreError.recoveryRequired
        }
        busy = true; defer { busy = false }
        protocolRestarts += 1
        try await client.closeForProtocolRecovery()
        consumer?.cancel(); await consumer?.value; consumer = nil
        for id in Array(pending.keys) { resolve(id, .uncertain(SafeFailure(.reconciliation, domain: .tdlib, cause: .interrupted))) }
        // Durable ownership is unchanged. Recovery must inventory these again;
        // closure alone does not establish remote acceptance or absence.
        pending.removeAll(); streamFailure = nil; census = nil; epoch = nil
        lastConnectionState = nil; historyRevision &+= 1; absenceCurrent = false
        try await client.start()
    }
    func nativeTransferSnapshot() async -> [TelegramNativeTransferStatus] {
        let connected = await client.connectionReady
        return pending.values.filter { $0.checkpoint.phase == .transferring || $0.checkpoint.phase == .uncertain }.map { item in
            TelegramNativeTransferStatus(transferID: item.checkpoint.transferID, destinationID: item.checkpoint.destinationID,
                jobID: item.checkpoint.jobID, resourceTag: item.checkpoint.tag, uploadedBytes: item.uploadedBytes, expectedBytes: item.state.byteCount,
                activity: streamFailure != nil || item.quarantined ? .uncertain : (!connected ? .waitingForConnection : (item.nativeActive ? .uploading : .awaitingAcknowledgement)))
        }
    }
    func mapVerifiedChannel(chatID: Int64) async throws -> Destination {
        guard !busy, pending.isEmpty else { throw CoreError.invalidTransition }; busy = true; defer { busy = false }
        try await startConsumer()
        let verified = try await verifyChannel(chatID)
        let body = try ProviderSupport.canonical(verified)
        let destination = try await ledger.selectDestination(Destination(provider: .telegram, verifiedFingerprint: ProviderSupport.fingerprint(body)))
        try await ledger.bindProviderProfile(destination: destination, profileID: client.profileID, scope: body)
        mapped = destination; scope = verified; epoch = nil; absenceCurrent = false
        return destination
    }
    private func verifyChannel(_ chatID: Int64) async throws -> Scope {
        guard await client.authorizationState == .ready, !(await client.requiresReconciliation), streamFailure == nil else {
            throw streamFailure ?? SafeFailure(.authentication, domain: .tdlib, cause: .loginRequired)
        }
        guard await client.connectionReady else { throw SafeFailure(.connectivity, domain: .tdlib, cause: .offline) }
        let me = try await client.getMe()
        let chat = try await client.request(["@type": "getChat", "chat_id": chatID])
        guard let userID = me["id"]?.int64Value, userID > 0, me.object(forKey: "type")?.type == "userTypeRegular",
              chat["id"]?.int64Value == chatID, chat["message_auto_delete_time"]?.int32Value == 0,
              let type = chat.object(forKey: "type"), type.type == "chatTypeSupergroup", type["is_channel"]?.boolValue == true,
              let groupID = type["supergroup_id"]?.int64Value else {
            throw SafeFailure(.accessDenied, domain: .tdlib, cause: .privateChannelRequired)
        }
        let group = try await client.request(["@type": "getSupergroup", "supergroup_id": groupID])
        // Creator access gives full channel history, even when it is hidden from
        // new members. Initially require an owned private archival channel.
        guard group["is_channel"]?.boolValue == true,
              group.object(forKey: "status")?.type == "chatMemberStatusCreator",
              group.object(forKey: "status")?["is_member"]?.boolValue == true,
              group.object(forKey: "usernames") == nil || group.object(forKey: "usernames")?.array(forKey: "active_usernames")?.isEmpty == true else {
            throw SafeFailure(.accessDenied, domain: .tdlib, cause: .privateChannelRequired)
        }
        _ = try await client.request(["@type": "getSupergroupFullInfo", "supergroup_id": groupID])
        return Scope(version: 1, userID: userID, chatID: chatID)
    }
    private func verify(_ destination: Destination) async throws {
        guard destination.provider == .telegram,
              let binding = try await ledger.providerBinding(destinationID: destination.id), binding.profileID == client.profileID else { throw CoreError.staleMapping }
        let saved = try JSONDecoder().decode(Scope.self, from: binding.scope)
        let verified = try await verifyChannel(saved.chatID)
        let body = try ProviderSupport.canonical(verified)
        guard verified == saved, ProviderSupport.fingerprint(body) == destination.verifiedFingerprint else { throw CoreError.staleMapping }
        if mapped?.id != destination.id { epoch = nil; absenceCurrent = false }
        mapped = destination; scope = verified
    }
    private func startConsumer() async throws {
        if consumer != nil { guard streamFailure == nil else { throw streamFailure! }; return }
        let updates = try await client.updates(types: [
            "updateNewMessage", "updateMessageSendSucceeded", "updateMessageSendFailed", "updateFile",
            "updateConnectionState", "updateDeleteMessages", "updateMessageContent", "updateMessageEdited"
        ])
        consumer = Task { [weak self] in
            do {
                for try await update in updates { guard let self else { return }; try await self.consume(update) }
                await self?.streamEnded(SafeFailure(.reconciliation, domain: .tdlib, cause: .interrupted))
            } catch { await self?.streamEnded(ProviderSupport.safe(error, domain: .tdlib)) }
        }
    }
    private func streamEnded(_ failure: SafeFailure) {
        streamFailure = failure; absenceCurrent = false; eventContinuation.yield(()); statusContinuation.yield(())
        for id in Array(pending.keys) { resolve(id, .uncertain(failure)) }
    }
    /// A malformed item or failed direct message lookup must not terminate the
    /// subscription and poison all future native sends. Stream loss, account
    /// restrictions and database failures still fail closed in the outer consumer.
    private func consume(_ update: TDLibResponse) async throws {
        do { try await handle(update) }
        catch {
            if ProviderSupport.blocksDestination(error, domain: .tdlib) || error is CancellationError { throw error }
            let failure = ProviderSupport.safe(error, domain: .tdlib)
            historyRevision &+= 1; absenceCurrent = false
            let message = update.object(forKey: "message")
            let sendingID = message?.object(forKey: "sending_state")?["sending_id"]?.int32Value
            let oldID = update["old_message_id"]?.int64Value
            let fileID = update.object(forKey: "file")?["id"]?.int32Value
            let affected = pending.filter { id, item in
                (sendingID == id && message?["chat_id"]?.int64Value == item.state.chatID) ||
                (oldID != nil && oldID == item.state.temporaryID && message?["chat_id"]?.int64Value == item.state.chatID) ||
                (fileID != nil && fileID == item.state.fileID)
            }
            if affected.isEmpty {
                try await ledger.appendEvent(.failure, context: EventContext(origin: .telegram),
                    decision: .reconcile, severity: .warning, failure: failure)
            }
            for (id, item) in affected {
                // Do not replace a terminal resolution when a later callback is
                // malformed. Holds/checkpoints remain owned until actual proof.
                if let result = pending[id]?.resolution {
                    switch result { case .confirmed, .rejected: continue; case .uncertain: break }
                }
                resolve(id, .uncertain(failure))
                try await ledger.appendEvent(.failure, context: EventContext(origin: .telegram,
                    destinationID: item.checkpoint.destinationID, jobID: item.checkpoint.jobID),
                    decision: .reconcile, severity: .warning, failure: failure)
            }
            eventContinuation.yield(()); statusContinuation.yield(())
        }
    }
    private func scanIndex(destination: Destination, chatID: Int64) async throws {
        guard !scanning else { throw CoreError.invalidTransition }; scanning = true
        let started = ProcessInfo.processInfo.systemUptime, operation = UUID()
        var reused = false
        censusRead = 0; statusContinuation.yield(())
        defer { scanning = false; censusRead = nil; statusContinuation.yield(()) }
        do {
            let progress: Census
            if let old = census, old.destinationID == destination.id, old.chatID == chatID,
               old.generation == historyRevision, started - old.advancedAt < 300 {
                // This also verifies the durable epoch has not been replaced.
                do { _ = try await ledger.remoteIndex(destinationID: destination.id, epoch: old.epoch, tag: String(repeating: "0", count: 64)) }
                catch { census = nil; throw error }
                progress = old; reused = true
            } else {
                census = nil
                progress = Census(destinationID: destination.id, chatID: chatID,
                    generation: historyRevision, epoch: try await ledger.beginRemoteIndex(destinationID: destination.id))
            }
            census = progress; epoch = nil; absenceCurrent = false
            try? await ledger.appendEvent(.setupTrace, context: EventContext(origin: .telegram, destinationID: destination.id,
                diagnostic: DiagnosticDetail(stage: .telegramCensus, status: .started, correlationID: operation,
                    items: progress.read, pages: progress.pages, reused: reused)), decision: .reconcile)
            var work = progress
            while !work.finished {
                try Task.checkCancellation()
                guard work.generation == historyRevision else { throw incompleteHistory() }
                let page = try await client.request(["@type": "searchChatMessages", "chat_id": chatID,
                    "query": "", "from_message_id": work.cursor, "offset": 0, "limit": 100,
                    "filter": ["@type": "searchMessagesFilterDocument"]])
                guard page.type == "foundChatMessages", let values = page.array(forKey: "messages"), values.count <= 100,
                      let next = page["next_from_message_id"]?.int64Value, next >= 0,
                      next == 0 || (next != work.cursor && (work.cursor == 0 || next < work.cursor)),
                      work.generation == historyRevision else { throw incompleteHistory() }
                var entries: [RemoteIndexEntry] = []
                for value in values {
                    guard let fields = value.objectValue else { throw incompleteHistory() }
                    if let reference = try TelegramDocumentReference.parse(TDLibResponse(fields: fields), chatID: chatID) {
                        entries.append(RemoteIndexEntry(tag: reference.tag, reference: try ProviderSupport.canonical(reference)))
                    }
                }
                try await ledger.addRemoteIndex(destinationID: destination.id, epoch: work.epoch, entries: entries)
                guard work.generation == historyRevision, next == 0 || !values.isEmpty else { throw incompleteHistory() }
                work.read += values.count; work.pages += 1; work.cursor = next; work.finished = next == 0
                work.advancedAt = ProcessInfo.processInfo.systemUptime
                census = work; censusRead = work.read; statusContinuation.yield(())
            }
            _ = try await verifyChannel(chatID)
            let interrupted = await client.requiresReconciliation
            guard historyRevision == work.generation, streamFailure == nil, !interrupted else { throw incompleteHistory() }
            try await ledger.finishRemoteIndex(destinationID: destination.id, epoch: work.epoch)
            guard historyRevision == work.generation, streamFailure == nil else { throw incompleteHistory() }
            epoch = work.epoch; absenceCurrent = true; census = nil
            try? await ledger.appendEvent(.setupTrace, context: EventContext(origin: .telegram, destinationID: destination.id,
                diagnostic: DiagnosticDetail(stage: .telegramCensus, status: .succeeded, correlationID: operation,
                    items: work.read, pages: work.pages, reused: reused)), decision: .proceed,
                duration: ProcessInfo.processInfo.systemUptime - started)
        } catch {
            if census?.generation != historyRevision { census = nil }
            try? await ledger.appendEvent(.setupTrace, context: EventContext(origin: .telegram, destinationID: destination.id,
                diagnostic: DiagnosticDetail(stage: .telegramCensus, status: .failed, correlationID: operation,
                    items: census?.read, pages: census?.pages, reused: reused)), decision: .reconcile,
                severity: .warning, failure: ProviderSupport.safe(error, domain: .tdlib),
                duration: ProcessInfo.processInfo.systemUptime - started)
            throw error
        }
    }
    func inspect(destination: Destination, resource: ResourceRequirement) async -> RemotePresence {
        guard !busy else { return .unknown(incompleteHistory()) }; busy = true; defer { busy = false }
        do {
            try await startConsumer(); try await verify(destination)
            guard let scope else { throw CoreError.staleMapping }
            var staleCheckpoint: ProviderCheckpoint?
            if let checkpoint = try await ledger.providerCheckpoint(destinationID: destination.id, tag: resource.tag), checkpoint.phase == .confirmed {
                let state = try JSONDecoder().decode(State.self, from: checkpoint.payload)
                if let reference = state.reference {
                    if try await validate(reference, resource: resource) {
                        return .present(try receipt(destination, reference, kind: .uploaded))
                    }
                    staleCheckpoint = checkpoint; absenceCurrent = false
                }
            }
            // Reconnects and pending-send recovery do not require a fresh census
            // to recognize an existing item. Validate positive candidates directly.
            if let epoch, let encoded = try await ledger.remoteIndex(destinationID: destination.id, epoch: epoch, tag: resource.tag).reference {
                let reference = try JSONDecoder().decode(TelegramDocumentReference.self, from: encoded)
                if try await validate(reference, resource: resource) {
                    return .present(try receipt(destination, reference, kind: .alreadyPresent))
                }
                absenceCurrent = false
            }
            if !absenceCurrent || epoch == nil { try await scanIndex(destination: destination, chatID: scope.chatID) }
            guard let epoch else { throw incompleteHistory() }
            let generation = historyRevision
            let lookup = try await ledger.remoteIndex(destinationID: destination.id, epoch: epoch, tag: resource.tag)
            if let encoded = lookup.reference {
                let reference = try JSONDecoder().decode(TelegramDocumentReference.self, from: encoded)
                guard try await validate(reference, resource: resource) else {
                    absenceCurrent = false; throw incompleteHistory()
                }
                // A matching old item does not settle an independently pending
                // send's file reader. The retained job is excluded by Core until settled.
                return .present(try receipt(destination, reference, kind: .alreadyPresent))
            }
            let connected = await client.connectionReady
            let interrupted = await client.requiresReconciliation
            guard absenceCurrent, historyRevision == generation, lookup.complete, connected, !interrupted,
                  !pending.values.contains(where: { $0.checkpoint.tag == resource.tag }) else { throw incompleteHistory() }
            if let staleCheckpoint {
                guard try await ledger.supersedeStaleTelegramCheckpoint(staleCheckpoint, epoch: epoch) else { throw incompleteHistory() }
            }
            if let old = try await ledger.providerCheckpoint(destinationID: destination.id, tag: resource.tag), old.phase != .rejected {
                return .unknown(SafeFailure(.reconciliation, domain: .tdlib, cause: .outcomeUnknown))
            }
            guard absenceCurrent, historyRevision == generation, streamFailure == nil else { throw incompleteHistory() }
            return .verifiedAbsent
        } catch {
            let safe = ProviderSupport.safe(error, domain: .tdlib)
            if safe.category == .rateLimit {
                return .destinationBlocked(safe, resumeAt: (error as? TDLibRequestRejection)?.retryAfter)
            }
            if ProviderSupport.blocksDestination(error, domain: .tdlib) { return .destinationBlocked(safe, resumeAt: nil) }
            return .unknown(safe)
        }
    }
    /// False means this well-formed cached candidate is missing/changed, not that
    /// the resource is absent. Only a subsequent full census can establish that.
    /// Operational, malformed-response and linked-manifest failures still throw.
    private func validate(_ reference: TelegramDocumentReference, resource: ResourceRequirement) async throws -> Bool {
        guard let scope else { throw CoreError.staleMapping }
        try reference.validate(chatID: scope.chatID, tag: resource.tag)
        let message: TDLibResponse
        do { message = try await client.request(["@type": "getMessage", "chat_id": scope.chatID, "message_id": reference.messageID]) }
        catch let rejection as TDLibRequestRejection where rejection.failure.code == 404 { return false }
        guard message.type == "message", message["chat_id"]?.int64Value == scope.chatID,
              message["id"]?.int64Value == reference.messageID, let content = message.object(forKey: "content"),
              content["@type"]?.stringValue?.hasPrefix("message") == true else { throw incompleteHistory() }
        if content.type != "messageDocument" { return false }
        guard let caption = content.object(forKey: "caption")?["text"]?.stringValue else { throw incompleteHistory() }
        if caption != ContentIdentity.version + ":" + resource.tag { return false }
        guard let actual = try TelegramDocumentReference.parse(message, chatID: scope.chatID),
              actual.tag == resource.tag, actual.remoteUniqueID == reference.remoteUniqueID,
              actual.byteCount == reference.byteCount else { return false }
        if resource.role == .manifest {
            let data = try await manifestData(actual)
            let document = try ArchiveManifestBuilder.validate(data, expectedTag: resource.tag)
            for item in document.confirmedReferences {
                let linked = try JSONDecoder().decode(TelegramDocumentReference.self, from: item.finalReference)
                try linked.validate(chatID: scope.chatID, tag: item.tag)
                guard let entry = document.recipe.resources.first(where: { $0.tag == item.tag }), entry.byteCount == linked.byteCount else { throw CoreError.invalidContract }
                let remote = try await client.request(["@type": "getMessage", "chat_id": scope.chatID, "message_id": linked.messageID])
                guard let found = try TelegramDocumentReference.parse(remote, chatID: scope.chatID, expectedTag: linked.tag),
                      found.remoteUniqueID == linked.remoteUniqueID, found.byteCount == linked.byteCount else { throw incompleteHistory() }
            }
        } else {
            guard resource.originals.count == 1, resource.originals[0].byteCount == reference.byteCount else { throw CoreError.invalidContract }
        }
        return true
    }
    private func manifestData(_ reference: TelegramDocumentReference) async throws -> Data {
        guard reference.byteCount <= 1_048_576 else { throw CoreError.invalidContract }
        let response = try await client.request(["@type": "downloadFile", "file_id": reference.fileID,
            "priority": 1, "offset": 0, "limit": reference.byteCount, "synchronous": true], timeout: 120)
        guard response.type == "file", response["size"]?.int64Value == reference.byteCount,
              let local = response.object(forKey: "local"), local["is_downloading_completed"]?.boolValue == true,
              let path = local["path"]?.stringValue else { throw incompleteHistory() }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let roots = try TDLibClient.storageURLs(forProfile: client.profileID)
        guard url.resolvingSymlinksInPath() == url, url.path.hasPrefix(roots.filesURL.path + "/") else { throw CoreError.invalidContract }
        let properties = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true,
              properties.fileSize.map(Int64.init) == reference.byteCount else { throw CoreError.invalidContract }
        let data = try Data(contentsOf: url)
        // Only the validated TD cache copy is removed; staging/Apple originals
        // cannot pass the canonical-root check above.
        _ = try await client.request(["@type": "deleteFile", "file_id": reference.fileID])
        return data
    }
    func upload(job: JobRecord, resource: ResourceRequirement, files inputs: [LeasedFile], transferID: UUID,
                progress: @escaping @Sendable (TransferProgress) async -> Void) async -> CloudifiedCore.UploadOutcome {
        guard !busy, pending.count < 8 else { return .failed(UploadFailure(SafeFailure(.reconciliation, domain: .tdlib, cause: .outcomeUnknown), disposition: .waiting, acceptance: .definitelyNotAccepted, didStartTransfer: false), .terminal) }
        busy = true; defer { busy = false }
        var submitted = false
        var sendReturned = false
        var sendingID: Int32?
        var state: State?
        let pump = ProviderProgressPump(resourceID: resource.id, report: progress); pump.start()
        do {
            try await startConsumer(); try await verify(job.destination)
            guard let scope, inputs.count == 1, let input = inputs.first else { throw CoreError.invalidContract }
            if let old = try await ledger.providerCheckpoint(destinationID: job.destination.id, tag: resource.tag), old.phase != .rejected { throw CoreError.recoveryRequired }
            let filename: String
            if resource.role == .manifest {
                guard input.byteCount <= 1_048_576 else { throw CoreError.invalidContract }
                _ = try ArchiveManifestBuilder.validate(Data(contentsOf: input.url), expectedTag: resource.tag)
                filename = "Cloudified-manifest-v2.json"
            } else {
                guard resource.originals.count == 1, input.byteCount == resource.originals[0].byteCount,
                      let data = try await ledger.sourceRecipe(assetID: job.asset.id) else { throw CoreError.invalidContract }
                let recipe = try JSONDecoder().decode(SourceRecipe.self, from: data); try recipe.validate()
                let content = resource.originals[0]
                let integrityStarted = ProcessInfo.processInfo.systemUptime
                let measured = try await ProviderSupport.hashFile(input.url)
                try? await ledger.appendEvent(.setupTrace, context: EventContext(origin: provider.origin,
                    destinationID: job.destination.id, jobID: job.id, resourceID: resource.id,
                    diagnostic: DiagnosticDetail(stage: .originalIntegrityCheck, status: .succeeded, correlationID: transferID)),
                    decision: .proceed, duration: ProcessInfo.processInfo.systemUptime - integrityStarted, bytes: measured.byteCount)
                guard measured.sha256 == content.sha256, measured.sha1 == content.sha1, measured.byteCount == content.byteCount else { throw CoreError.invalidContract }
                if let part = content.partIndex {
                    guard let master = recipe.videoSplits.first(where: { $0.parts.contains(where: { $0.originalContent == content }) }),
                          let original = recipe.resources.first(where: { $0.sha256 == master.originalSha256 && $0.role == master.role }) else { throw CoreError.invalidContract }
                    filename = String(decoding: Array(original.originalFilename.utf8.prefix(180)), as: UTF8.self) + ".part-\(part + 1)-of-\(content.partCount ?? 0)"
                } else {
                    guard let original = recipe.resources.first(where: { $0.originalContent == content }) else { throw CoreError.invalidContract }
                    filename = original.originalFilename
                }
            }
            // Account for a possible full native copy while both provider lanes
            // share staging. No second staged media copy is created by this app.
            try await ledger.reserveTransport(transferID, bytes: input.byteCount, availableBytes: ProviderSupport.availableBytes(at: input.url))
            guard nextSendingID < Int32.max else { throw CoreError.invalidTransition }
            let id = nextSendingID; nextSendingID += 1; sendingID = id
            var value = State(chatID: scope.chatID, sendingID: id, byteCount: input.byteCount, filename: filename)
            state = value
            try await save(job: job, resource: resource, transferID: transferID, phase: .prepared, state: value, terminal: true)
            let path = try inputFiles.create(transferID: transferID, input: input, filename: filename)
            let checkpoint = try await save(job: job, resource: resource, transferID: transferID, phase: .transferring, state: value, terminal: false)
            pending[id] = Pending(checkpoint: checkpoint, state: value, pump: pump)
            try Task.checkCancellation()
            submitted = true // Persisted/registered before handing the command to native.
            let sent = try await client.request(["@type": "sendMessage", "chat_id": scope.chatID,
                "options": ["@type": "messageSendOptions", "disable_notification": true, "sending_id": id],
                "input_message_content": ["@type": "inputMessageDocument",
                    "document": ["@type": "inputDocument", "document": ["@type": "inputFileLocal", "path": path.path], "disable_content_type_detection": true],
                    "caption": ["@type": "formattedText", "text": try ContentIdentity.telegramCaptionTag(resource), "entities": []]]])
            sendReturned = true
            try await capture(sent, sendingID: id)
            if let updated = pending[id]?.state { value = updated; state = value }
            let result = await awaitResolution(id)
            await pump.stop()
            switch pending[id]?.resolution ?? result {
            case .confirmed(let reference):
                pending.removeValue(forKey: id)
                return .confirmed(try receipt(job.destination, reference, kind: .uploaded), .terminal)
            case .rejected(let failure, let delay):
                pending.removeValue(forKey: id)
                return .failed(UploadFailure(failure, disposition: ProviderSupport.disposition(failure), acceptance: .definitelyNotAccepted, retryAfter: delay.map { Date().addingTimeInterval($0) }), .terminal)
            case .uncertain(let failure):
                pending[id]?.pump = nil
                return .failed(UploadFailure(failure, disposition: .waiting, acceptance: .unknown), .retainedByTransport)
            }
        } catch {
            await pump.stop()
            let safe = ProviderSupport.safe(error, domain: .tdlib)
            // At the pinned revision, sendMessage returns a native Error before
            // get_message_to_send/save_send_message_log_event/do_send_message.
            // Local document input with no thumbnail/conversion has no upload
            // reader in that branch. Bridge timeouts/cancellation are excluded.
            if submitted, !sendReturned, error is TDLibRequestRejection, let id = sendingID,
               pending[id]?.state.temporaryID == nil { submitted = false }
            if !submitted {
                if let id = sendingID { pending.removeValue(forKey: id) }
                if let state {
                    do {
                        try await save(job: job, resource: resource, transferID: transferID, phase: .rejected, state: state, terminal: true)
                        try inputFiles.remove(transferID: transferID)
                    } catch { return .failed(UploadFailure(ProviderSupport.safe(error, domain: .tdlib), disposition: .waiting, acceptance: .unknown, didStartTransfer: false), .retainedByTransport) }
                }
                let preSendWait = safe.category == .connectivity || safe.category == .timeout
                return .failed(UploadFailure(safe, disposition: preSendWait ? .waiting : ProviderSupport.disposition(safe), acceptance: .definitelyNotAccepted,
                    retryAfter: (error as? TDLibRequestRejection)?.retryAfter, didStartTransfer: false), .terminal)
            }
            if let id = sendingID {
                pending[id]?.pump = nil
                if let result = pending[id]?.resolution {
                    switch result {
                    case .confirmed(let reference):
                        pending.removeValue(forKey: id)
                        do { return .confirmed(try receipt(job.destination, reference, kind: .uploaded), .terminal) }
                        catch { return .failed(UploadFailure(ProviderSupport.safe(error, domain: .tdlib), disposition: .waiting, acceptance: .unknown), .terminal) }
                    case .rejected(let failure, let delay):
                        pending.removeValue(forKey: id)
                        return .failed(UploadFailure(failure, disposition: ProviderSupport.disposition(failure), acceptance: .definitelyNotAccepted, retryAfter: delay.map { Date().addingTimeInterval($0) }), .terminal)
                    case .uncertain: break
                    }
                }
            }
            return .failed(UploadFailure(safe, disposition: ProviderSupport.disposition(safe), acceptance: .unknown), .retainedByTransport)
        }
    }
    @discardableResult private func save(job: JobRecord, resource: ResourceRequirement, transferID: UUID,
        phase: ProviderCheckpointPhase, state: State, terminal: Bool) async throws -> ProviderCheckpoint {
        let checkpoint = ProviderCheckpoint(destinationID: job.destination.id, tag: resource.tag, transferID: transferID,
            jobID: job.id, phase: phase, inputsTerminal: terminal, payload: try ProviderSupport.canonical(state))
        try await ledger.saveProviderCheckpoint(checkpoint); return checkpoint
    }
    private func capture(_ message: TDLibResponse, sendingID: Int32) async throws {
        guard var item = pending[sendingID], message["chat_id"]?.int64Value == item.state.chatID,
              try TelegramDocumentReference.captionTag(message) == item.checkpoint.tag else { throw CoreError.invalidContract }
        if let resolution = item.resolution {
            switch resolution { case .confirmed, .rejected: return; case .uncertain: break }
        }
        if let final = try? TelegramDocumentReference.parse(message, chatID: item.state.chatID, expectedTag: item.checkpoint.tag) {
            try await finish(sendingID, reference: final); return
        }
        guard let temporary = message["id"]?.int64Value, temporary > 0,
              let sending = message.object(forKey: "sending_state") else { throw incompleteHistory() }
        item.state.temporaryID = temporary
        let file = message.object(forKey: "content")?.object(forKey: "document")?.object(forKey: "document")
        item.state.fileID = file?["id"]?.int32Value
        item.quarantined = false
        item.inputInventoried = (item.state.fileID ?? 0) > 0 && file?["size"]?.int64Value == item.state.byteCount
        if let sent = file?.object(forKey: "remote")?["uploaded_size"]?.int64Value {
            item.uploadedBytes = min(max(0, sent), item.state.byteCount)
            item.nativeActive = file?.object(forKey: "remote")?["is_uploading_active"]?.boolValue == true
            item.pump?.offer(item.uploadedBytes, item.state.byteCount)
        }
        pending[sendingID] = item
        statusContinuation.yield(())
        try await persistPending(sendingID, phase: .transferring, terminal: false)
        if sending.type == "messageSendingStateFailed" { try await reject(sendingID, message: message, error: sending.object(forKey: "error")) }
    }
    private func handle(_ update: TDLibResponse) async throws {
        guard streamFailure == nil else { return }
        switch update.type {
        case "updateNewMessage":
            guard let message = update.object(forKey: "message"), message["chat_id"]?.int64Value == scope?.chatID else { return }
            if let id = try matchingPending(message) { try await capture(message, sendingID: id) }
            else if message.object(forKey: "sending_state") == nil { try await indexNew(message) }
        case "updateMessageSendSucceeded", "updateMessageSendFailed":
            guard let message = update.object(forKey: "message"), let old = update["old_message_id"]?.int64Value,
                  let id = try matchingPending(message, oldMessageID: old) else { return }
            if pending[id]?.state.temporaryID == nil { pending[id]?.state.temporaryID = old }
            guard let item = pending[id] else { return }
            if update.type == "updateMessageSendSucceeded" {
                guard let reference = try TelegramDocumentReference.parse(message, chatID: item.state.chatID, expectedTag: item.checkpoint.tag) else { throw incompleteHistory() }
                try await finish(id, reference: reference)
            } else { try await capture(message, sendingID: id) }
        case "updateFile":
            guard let file = update.object(forKey: "file"), let id = file["id"]?.int32Value,
                  let key = pending.first(where: { $0.value.state.fileID == id })?.key, let item = pending[key],
                  let uploaded = file.object(forKey: "remote")?["uploaded_size"]?.int64Value else { return }
            let bytes = min(max(0, uploaded), item.state.byteCount)
            if bytes > item.uploadedBytes { pending[key]?.lastByteAdvance = ProcessInfo.processInfo.systemUptime }
            pending[key]?.uploadedBytes = bytes
            pending[key]?.nativeActive = file.object(forKey: "remote")?["is_uploading_active"]?.boolValue == true
            item.pump?.offer(bytes, item.state.byteCount)
            statusContinuation.yield(())
        case "updateConnectionState":
            let state = update.object(forKey: "state")?.type
            if state != lastConnectionState {
                lastConnectionState = state; historyRevision &+= 1; absenceCurrent = false
                if state == "connectionStateReady" { eventContinuation.yield(()) }
            }
            statusContinuation.yield(())
        case "updateDeleteMessages", "updateMessageContent", "updateMessageEdited":
            if update["chat_id"]?.int64Value == scope?.chatID { historyRevision &+= 1; absenceCurrent = false }
        default: break
        }
    }
    private func matchingPending(_ message: TDLibResponse, oldMessageID: Int64? = nil) throws -> Int32? {
        guard let tag = try TelegramDocumentReference.captionTag(message) else { return nil }
        for (id, item) in pending where item.state.chatID == message["chat_id"]?.int64Value && item.checkpoint.tag == tag {
            if let oldMessageID, item.inputInventoried, !item.quarantined, item.state.temporaryID == oldMessageID { return id }
            let expected = try inputFiles.url(transferID: item.checkpoint.transferID, filename: item.state.filename).path
            if try Self.matchesOwnedMessage(message, chatID: item.state.chatID, tag: tag,
                expectedPath: expected, byteCount: item.state.byteCount) { return id }
        }
        return nil
    }
    private func indexNew(_ message: TDLibResponse) async throws {
        historyRevision &+= 1
        guard let destination = mapped, let scope else { return }
        if let reference = try TelegramDocumentReference.parse(message, chatID: scope.chatID), let epoch, !scanning {
            try await ledger.addRemoteIndex(destinationID: destination.id, epoch: epoch, entries: [RemoteIndexEntry(tag: reference.tag, reference: ProviderSupport.canonical(reference))])
        }
    }
    private func finish(_ id: Int32, reference: TelegramDocumentReference) async throws {
        historyRevision &+= 1
        guard var item = pending[id] else { return }
        guard reference.byteCount == item.state.byteCount else { throw CoreError.invalidContract }
        let message = try await client.request(["@type": "getMessage", "chat_id": reference.chatID, "message_id": reference.messageID])
        guard let actual = try TelegramDocumentReference.parse(message, chatID: reference.chatID, expectedTag: reference.tag), actual.remoteUniqueID == reference.remoteUniqueID else { throw incompleteHistory() }
        item.state.reference = actual; pending[id] = item
        try await persistPending(id, phase: .confirmed, terminal: true)
        let job = try await ledger.job(item.checkpoint.jobID)
        guard let resource = job.plan.resources.first(where: { $0.tag == item.checkpoint.tag }) else { throw CoreError.invalidContract }
        // Commit actual late confirmations too; Saved never waits for a blind
        // replacement send. Engine may idempotently commit the same receipt later.
        try await ledger.confirm(receipt(job.destination, actual, kind: .uploaded), jobID: job.id, resourceID: resource.id)
        try inputFiles.remove(transferID: item.checkpoint.transferID)
        try await files.transportFinished(item.checkpoint.transferID)
        resolve(id, .confirmed(actual))
        if let destination = mapped, let epoch, !scanning {
            try await ledger.addRemoteIndex(destinationID: destination.id, epoch: epoch, entries: [RemoteIndexEntry(tag: actual.tag, reference: ProviderSupport.canonical(actual))])
        }
        try await ledger.wakeWaiting(destinationID: item.checkpoint.destinationID)
        eventContinuation.yield(()); statusContinuation.yield(())
        if pending[id]?.waiter == nil, pending[id]?.pump == nil { pending.removeValue(forKey: id) }
    }
    private func reject(_ id: Int32, message: TDLibResponse, error: TDLibResponse?) async throws {
        guard let item = pending[id], let fileID = item.state.fileID ?? message.object(forKey: "content")?.object(forKey: "document")?.object(forKey: "document")?["id"]?.int32Value else { throw incompleteHistory() }
        let file = try await client.request(["@type": "getFile", "file_id": fileID])
        guard file.type == "file", file["id"]?.int32Value == fileID,
              file["size"]?.int64Value == item.state.byteCount,
              let active = file.object(forKey: "remote")?["is_uploading_active"]?.boolValue,
              message.object(forKey: "sending_state")?.type == "messageSendingStateFailed" else { throw incompleteHistory() }
        // Cancellation of the failed message's native reader may still be in
        // flight. Keep its hold and allow recovery of the other items to finish.
        if active { return }
        guard let current = pending[id], !current.checkpoint.inputsTerminal,
              current.state.fileID == fileID else { return }
        let code = error?["code"]?.int32Value ?? 0
        let delay = TDLibClient.retryDelay(code: code, message: error?["message"]?.stringValue ?? "",
            explicit: message.object(forKey: "sending_state")?["retry_after"])
        let limited = TDLibClient.isRateLimit(code: code, message: error?["message"]?.stringValue ?? "")
        let expired = code == 400 && error?["message"]?.stringValue == "Message is too old to be re-sent automatically"
        let safe = SafeFailure(limited ? .rateLimit : (code == 401 ? .authentication : (code == 403 ? .accessDenied : (code == 400 && !expired ? .unsupportedOriginal : .transfer))), domain: .tdlib, code: Int(code),
                               cause: limited ? .serverRateLimit : (code == 401 ? .loginRequired : (expired ? .interrupted : .providerRejected)))
        let rejection = UploadFailure(safe, disposition: ProviderSupport.disposition(safe), acceptance: .definitelyNotAccepted,
                                      retryAfter: delay.map { Date().addingTimeInterval($0) })
        try await persistPending(id, phase: .rejected, terminal: true, failure: rejection)
        let job = try await ledger.job(item.checkpoint.jobID)
        guard let resource = job.plan.resources.first(where: { $0.tag == item.checkpoint.tag }) else { throw CoreError.invalidContract }
        try await ledger.appendEvent(.failure, context: ProviderSupport.context(job, resource), decision: .retry, severity: .error, failure: safe)
        if pending[id]?.pump == nil {
            try await ledger.failAttempt(jobID: job.id, failure: rejection, resourceID: resource.id, transferID: item.checkpoint.transferID)
        }
        try inputFiles.remove(transferID: item.checkpoint.transferID)
        try await files.transportFinished(item.checkpoint.transferID)
        resolve(id, .rejected(safe, delay))
        try await ledger.wakeWaiting(destinationID: item.checkpoint.destinationID)
        eventContinuation.yield(()); statusContinuation.yield(())
        if pending[id]?.waiter == nil, pending[id]?.pump == nil { pending.removeValue(forKey: id) }
    }
    private func persistPending(_ id: Int32, phase: ProviderCheckpointPhase, terminal: Bool, failure: UploadFailure? = nil) async throws {
        guard let item = pending[id] else { throw CoreError.invalidTransition }
        let checkpoint = ProviderCheckpoint(destinationID: item.checkpoint.destinationID, tag: item.checkpoint.tag,
            transferID: item.checkpoint.transferID, jobID: item.checkpoint.jobID, phase: phase,
            inputsTerminal: terminal, payload: try ProviderSupport.canonical(item.state), failure: failure)
        try await ledger.saveProviderCheckpoint(checkpoint)
        pending[id]?.checkpoint = checkpoint
    }
    private func awaitResolution(_ id: Int32) async -> Resolution {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard let item = pending[id] else { continuation.resume(returning: .uncertain(incompleteHistory())); return }
                if let result = item.resolution { continuation.resume(returning: result); return }
                pending[id]?.waiter = continuation
                pending[id]?.deadline = Task { [weak self] in
                    // Large videos can legitimately exceed five minutes. Only
                    // five minutes without real byte advancement ends the waiter.
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(30)) } catch { return }
                        guard let self else { return }
                        if await self.expireStalledSend(id) { return }
                    }
                }
                if Task.isCancelled { resolve(id, .uncertain(SafeFailure(.connectivity, domain: .tdlib, cause: .interrupted))) }
            }
        } onCancel: { Task { await self.resolve(id, .uncertain(SafeFailure(.connectivity, domain: .tdlib, cause: .interrupted))) } }
    }
    private func expireStalledSend(_ id: Int32) -> Bool {
        guard let item = pending[id], item.waiter != nil else { return true }
        guard ProcessInfo.processInfo.systemUptime - item.lastByteAdvance >= 300 else { return false }
        resolve(id, .uncertain(SafeFailure(.timeout, domain: .tdlib, cause: .deadlineExceeded))); return true
    }
    private func resolve(_ id: Int32, _ resolution: Resolution) {
        guard var item = pending[id] else { return }
        if let previous = item.resolution {
            switch previous {
            case .confirmed, .rejected: return // Terminal native evidence wins cancellation/timeouts.
            case .uncertain: break // A later verified result may still settle this send.
            }
        }
        item.resolution = resolution; item.deadline?.cancel(); item.deadline = nil
        let waiter = item.waiter; item.waiter = nil; pending[id] = item
        waiter?.resume(returning: resolution)
    }
    func recover(_ destination: Destination) async throws {
        let started = ProcessInfo.processInfo.systemUptime, operation = UUID()
        do {
            try await recoverInputs(destination)
            try? await ledger.appendEvent(.setupTrace, context: EventContext(origin: .telegram, destinationID: destination.id,
                diagnostic: DiagnosticDetail(stage: .telegramRecovery, status: .succeeded, correlationID: operation,
                    items: pending.values.filter { $0.checkpoint.destinationID == destination.id && $0.quarantined }.count)),
                decision: .reconcile, duration: ProcessInfo.processInfo.systemUptime - started)
        } catch {
            try? await ledger.appendEvent(.setupTrace, context: EventContext(origin: .telegram, destinationID: destination.id,
                diagnostic: DiagnosticDetail(stage: .telegramRecovery, status: .failed, correlationID: operation)),
                decision: .reconcile, severity: .warning, failure: ProviderSupport.safe(error, domain: .tdlib),
                duration: ProcessInfo.processInfo.systemUptime - started)
            throw error
        }
    }
    private func recoverInputs(_ destination: Destination) async throws {
        guard !busy else { throw CoreError.invalidTransition }; busy = true; defer { busy = false }
        try await startConsumer(); try await verify(destination)
        guard let scope else { throw CoreError.staleMapping }
        // Recovery verifies scope and actual pending readers. Defer the expensive
        // census until an inspection really needs absence; positives stay reusable.
        var cursor: UUID?
        while true {
            let page = try await ledger.retainedTransfers(destinationID: destination.id, afterID: cursor)
            if page.isEmpty { break }
            for transfer in page {
                cursor = transfer.id
                guard let checkpoint = try await ledger.providerCheckpoint(destinationID: destination.id, tag: transfer.resource.tag) else {
                    // Crash before the checkpoint fence: no command could be sent.
                    try inputFiles.remove(transferID: transfer.id); try await files.transportFinished(transfer.id); continue
                }
                let state = try JSONDecoder().decode(State.self, from: checkpoint.payload)
                guard checkpoint.transferID == transfer.id, checkpoint.jobID == transfer.job.id else { throw CoreError.recoveryRequired }
                guard state.chatID == scope.chatID else { throw CoreError.staleMapping }
                if checkpoint.phase == .prepared || checkpoint.phase == .rejected || checkpoint.phase == .confirmed {
                    if checkpoint.phase == .prepared {
                        try await save(job: transfer.job, resource: transfer.resource, transferID: transfer.id, phase: .rejected, state: state, terminal: true)
                    }
                    try inputFiles.remove(transferID: transfer.id); try await files.transportFinished(transfer.id); continue
                }
                let existing = pending.first(where: { $0.value.checkpoint.transferID == transfer.id })?.key
                let id: Int32
                if let existing { id = existing }
                else {
                    guard pending.count < 8, nextSendingID < Int32.max else { throw CoreError.recoveryRequired }
                    id = nextSendingID; nextSendingID += 1
                    // Install before awaits: a late success update must be able
                    // to match this transfer while history lookup is in flight.
                    pending[id] = Pending(checkpoint: checkpoint, state: state)
                }
                if let item = pending[id], item.quarantined, let last = item.lastRecoveryLookup,
                   ProcessInfo.processInfo.systemUptime - last < 30 {
                    try inputFiles.verifyProtected(transferID: transfer.id, filename: state.filename, byteCount: state.byteCount)
                    continue
                }
                pending[id]?.lastRecoveryLookup = ProcessInfo.processInfo.systemUptime
                var message: TDLibResponse?
                if let temporary = state.temporaryID {
                    do {
                        let candidate = try await client.request(["@type": "getMessage", "chat_id": scope.chatID, "message_id": temporary], timeout: 5)
                        let expected = try inputFiles.url(transferID: transfer.id, filename: state.filename).path
                        if try Self.matchesOwnedMessage(candidate, chatID: state.chatID, tag: checkpoint.tag,
                            expectedPath: expected, byteCount: state.byteCount) { message = candidate }
                    } catch { try await deferOwnedLookup(error, checkpoint: checkpoint, lookup: .directMessage) }
                }
                if message == nil {
                    message = try await findOwnedMessage(checkpoint: checkpoint, state: state)
                    try? await ledger.appendEvent(.setupTrace,
                        context: EventContext(origin: .telegram, destinationID: destination.id,
                            jobID: checkpoint.jobID,
                            diagnostic: DiagnosticDetail(stage: .telegramRecovery, status: .changed,
                                correlationID: UUID(), available: message != nil)),
                        decision: .reconcile)
                }
                // A matching update may have settled ownership during lookup.
                guard let current = try await ledger.providerCheckpoint(destinationID: destination.id, tag: checkpoint.tag),
                      current.transferID == transfer.id else { throw CoreError.recoveryRequired }
                if current.inputsTerminal { continue }
                guard pending[id] != nil else { throw CoreError.recoveryRequired }
                guard let message else {
                    try inputFiles.verifyProtected(transferID: transfer.id, filename: state.filename, byteCount: state.byteCount)
                    let newlyQuarantined = pending[id]?.quarantined != true
                    let failure = SafeFailure(.reconciliation, domain: .tdlib, cause: .pendingSendUnmatched)
                    guard let item = pending[id] else { continue }
                    let quarantined = ProviderCheckpoint(destinationID: item.checkpoint.destinationID,
                        tag: item.checkpoint.tag, transferID: transfer.id, jobID: item.checkpoint.jobID,
                        phase: .uncertain, inputsTerminal: false, payload: try ProviderSupport.canonical(item.state))
                    guard try await ledger.quarantineTelegramTransfer(quarantined) else { continue }
                    guard pending[id]?.checkpoint.inputsTerminal == false else { continue }
                    pending[id]?.checkpoint = quarantined
                    pending[id]?.quarantined = true
                    pending[id]?.inputInventoried = true
                    resolve(id, .uncertain(failure))
                    if newlyQuarantined {
                        try await ledger.failAttempt(jobID: transfer.job.id,
                            failure: UploadFailure(failure, disposition: .waiting, acceptance: .unknown, didStartTransfer: false),
                            resourceID: transfer.resource.id, transferID: transfer.id)
                    }
                    continue // Keep this hold; admit other independently checked assets.
                }
                try await capture(message, sendingID: id)
            }
        }
        // A matched native send owns its inputs and stays excluded from claimNext.
        // It does not block unrelated assets; their own inspections must establish
        // fresh presence/absence before any sending is admitted.
        let owned = Set(pending.values.filter { $0.checkpoint.destinationID == destination.id && $0.inputInventoried && !$0.quarantined }.map { $0.checkpoint.transferID })
        let protected = Set(pending.values.filter { $0.checkpoint.destinationID == destination.id && $0.quarantined }.map { $0.checkpoint.transferID })
        try await ledger.completeDestinationRecovery(destination.id, inventoriedLiveTransfers: owned,
                                                     protectedUnresolvedTransfers: protected)
    }
    private func traceOwnedLookup(_ checkpoint: ProviderCheckpoint, pages: Int, candidates: Int, found: Bool, local: Bool) async {
        try? await ledger.appendEvent(.setupTrace,
            context: EventContext(origin: .telegram, destinationID: checkpoint.destinationID, jobID: checkpoint.jobID,
                diagnostic: DiagnosticDetail(stage: .telegramRecovery, status: .changed, correlationID: UUID(),
                    available: found, items: candidates, pages: pages, reused: local)), decision: .reconcile)
    }
    private enum OwnedLookupFailure: Error { case responseInvalid, cursorDidNotAdvance }
    private func deferOwnedLookup(_ error: any Error, checkpoint: ProviderCheckpoint, lookup: DiagnosticRecoveryLookup) async throws {
        try Task.checkCancellation()
        if error is CancellationError { throw error }
        let failure = ProviderSupport.safe(error, domain: .tdlib)
        let issue: DiagnosticRecoveryIssue
        if let lookupError = error as? OwnedLookupFailure {
            issue = lookupError == .cursorDidNotAdvance ? .cursorDidNotAdvance : .responseInvalid
        } else if failure.category == .reconciliation && failure.cause == .incompleteHistory {
            issue = .responseInvalid
        } else if failure.domain == .tdlib && failure.category == .transfer && failure.code == 404 {
            issue = .requestRejected
        } else if failure.domain == .tdlib && failure.category == .timeout && failure.cause == .deadlineExceeded {
            issue = .requestTimedOut
        } else { throw error }
        await traceLookupDeferral(checkpoint, lookup: lookup, issue: issue)
    }
    private func traceLookupDeferral(_ checkpoint: ProviderCheckpoint, lookup: DiagnosticRecoveryLookup, issue: DiagnosticRecoveryIssue) async {
        try? await ledger.appendEvent(.setupTrace,
            context: EventContext(origin: .telegram, destinationID: checkpoint.destinationID, jobID: checkpoint.jobID,
                diagnostic: DiagnosticDetail(stage: .telegramRecovery, status: .changed, correlationID: UUID(),
                    recoveryLookup: lookup, recoveryIssue: issue)), decision: .reconcile, severity: .warning,
            failure: SafeFailure(.reconciliation, domain: .tdlib, cause: .incompleteHistory))
    }
    /// A positive lookup miss never proves absence or releases a native reader.
    private func findOwnedMessage(checkpoint: ProviderCheckpoint, state: State) async throws -> TDLibResponse? {
        let expected = try inputFiles.url(transferID: checkpoint.transferID, filename: state.filename).path
        do {
            if let failed = try await findFailedMessage(checkpoint: checkpoint, state: state, expectedPath: expected) { return failed }
        } catch { try await deferOwnedLookup(error, checkpoint: checkpoint, lookup: .failedOutbox) }
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        do {
            if let recent = try await findRecentMessage(checkpoint: checkpoint, state: state, expectedPath: expected, deadline: deadline) { return recent }
        } catch { try await deferOwnedLookup(error, checkpoint: checkpoint, lookup: .localHistory) }
        do {
            return try await findServerMessage(checkpoint: checkpoint, state: state, expectedPath: expected, deadline: deadline)
        } catch { try await deferOwnedLookup(error, checkpoint: checkpoint, lookup: .serverSearch) }
        return nil
    }
    private func findRecentMessage(checkpoint: ProviderCheckpoint, state: State, expectedPath: String, deadline: TimeInterval) async throws -> TDLibResponse? {
        var pages = 0
        var candidates = Set<Int64>()
        var cursor: Int64 = 0
        for _ in 0..<3 {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            let page = try await client.request(["@type": "getChatHistory", "chat_id": state.chatID,
                "from_message_id": cursor, "offset": 0, "limit": 100, "only_local": true], timeout: min(3, remaining))
            guard page.type == "messages", let values = page.array(forKey: "messages"), values.count <= 100 else { throw OwnedLookupFailure.responseInvalid }
            var oldest = cursor
            pages += 1
            for value in values {
                guard let fields = value.objectValue else { throw OwnedLookupFailure.responseInvalid }
                let message = TDLibResponse(fields: fields)
                guard let id = message["id"]?.int64Value, id > 0 else { throw OwnedLookupFailure.responseInvalid }
                if oldest == 0 || id < oldest { oldest = id }
                if (try? TelegramDocumentReference.captionTag(message)) == checkpoint.tag { candidates.insert(id) }
                if try Self.matchesOwnedMessage(message, chatID: state.chatID, tag: checkpoint.tag,
                    expectedPath: expectedPath, byteCount: state.byteCount) {
                    await traceOwnedLookup(checkpoint, pages: pages, candidates: candidates.count, found: true, local: true)
                    return message
                }
            }
            if values.isEmpty || oldest == cursor { break }
            cursor = oldest
        }
        await traceOwnedLookup(checkpoint, pages: pages, candidates: candidates.count, found: false, local: true)
        return nil
    }
    private func findServerMessage(checkpoint: ProviderCheckpoint, state: State, expectedPath: String, deadline: TimeInterval) async throws -> TDLibResponse? {
        var pages = 0
        var candidates = Set<Int64>()
        var cursor: Int64 = 0
        var visited = Set<Int64>()
        for _ in 0..<3 {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            guard visited.insert(cursor).inserted else { throw OwnedLookupFailure.cursorDidNotAdvance }
            let page = try await client.request(["@type": "searchChatMessages", "chat_id": state.chatID,
                "query": ContentIdentity.version + ":" + checkpoint.tag, "from_message_id": cursor,
                "offset": 0, "limit": 100, "filter": ["@type": "searchMessagesFilterDocument"]], timeout: min(5, remaining))
            guard page.type == "foundChatMessages", let values = page.array(forKey: "messages"), values.count <= 100,
                  let next = page["next_from_message_id"]?.int64Value, next >= 0 else { throw OwnedLookupFailure.responseInvalid }
            pages += 1
            for value in values {
                guard let fields = value.objectValue else { throw OwnedLookupFailure.responseInvalid }
                let message = TDLibResponse(fields: fields)
                guard let id = message["id"]?.int64Value, id > 0 else { throw OwnedLookupFailure.responseInvalid }
                if (try? TelegramDocumentReference.captionTag(message)) == checkpoint.tag { candidates.insert(id) }
                if try Self.matchesOwnedMessage(message, chatID: state.chatID, tag: checkpoint.tag,
                    expectedPath: expectedPath, byteCount: state.byteCount) {
                    await traceOwnedLookup(checkpoint, pages: pages, candidates: candidates.count, found: true, local: false)
                    return message
                }
            }
            if next == 0 { break }
            cursor = next
        }
        await traceOwnedLookup(checkpoint, pages: pages, candidates: candidates.count, found: false, local: false)
        return nil
    }
    /// Failed sends can be older than the recent-history window and are not
    /// returned by the server document search. This filter requires an empty
    /// query; apply our exact transfer identity locally to each bounded page.
    private func findFailedMessage(checkpoint: ProviderCheckpoint, state: State, expectedPath: String) async throws -> TDLibResponse? {
        var cursor: Int64 = 0
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        for _ in 0..<3 {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            let page = try await client.request(["@type": "searchChatMessages", "chat_id": state.chatID,
                "query": "", "from_message_id": cursor, "offset": 0, "limit": 100,
                "filter": ["@type": "searchMessagesFilterFailedToSend"]], timeout: min(3, remaining))
            guard page.type == "foundChatMessages", let values = page.array(forKey: "messages"), values.count <= 100,
                  let next = page["next_from_message_id"]?.int64Value, next >= 0 else { throw OwnedLookupFailure.responseInvalid }
            for value in values {
                guard let fields = value.objectValue else { throw OwnedLookupFailure.responseInvalid }
                let message = TDLibResponse(fields: fields)
                if try Self.matchesOwnedMessage(message, chatID: state.chatID, tag: checkpoint.tag,
                    expectedPath: expectedPath, byteCount: state.byteCount) { return message }
            }
            if next == 0 { break }
            guard next != cursor && (cursor == 0 || next < cursor) else { throw OwnedLookupFailure.cursorDidNotAdvance }
            guard !values.isEmpty else { throw OwnedLookupFailure.responseInvalid }
            cursor = next
        }
        return nil
    }
    static func matchesOwnedMessage(_ message: TDLibResponse, chatID: Int64, tag: String,
                                    expectedPath: String, byteCount: Int64) throws -> Bool {
        guard message.type == "message", message["chat_id"]?.int64Value == chatID,
              let file = message.object(forKey: "content")?.object(forKey: "document")?.object(forKey: "document"),
              let actualPath = file.object(forKey: "local")?["path"]?.stringValue,
              TelegramInputFiles.matchesOwnedPath(actualPath, expected: expectedPath),
              file["size"]?.int64Value == byteCount,
              try TelegramDocumentReference.captionTag(message) == tag else { return false }
        if message.object(forKey: "sending_state") != nil { return true }
        return try TelegramDocumentReference.parse(message, chatID: chatID, expectedTag: tag) != nil
    }

    /// Settings/P6 call before discarding the adapter. Genuine native close is
    /// required, but uncertain pending paths remain protected for DB resumption.
    func close() async throws {
        guard !busy else { throw CoreError.invalidTransition }
        try await client.close(); consumer?.cancel(); await consumer?.value; consumer = nil; eventContinuation.finish(); statusContinuation.finish()
        streamFailure = SafeFailure(.reconciliation, domain: .tdlib, cause: .interrupted); epoch = nil
    }
    /// Native cache only. No original/DB/remote-message deletion. Called once at
    /// idle after global input inventory proves there are no retained readers.
    func trimIdleCache() async throws {
        guard !busy, pending.isEmpty, await client.authorizationState == .ready,
              await client.connectionReady else { return }
        busy = true; defer { busy = false }
        _ = try await client.request(["@type": "optimizeStorage", "size": 67_108_864,
            "ttl": 604800, "count": 1000, "immunity_delay": 0,
            "file_types": [["@type": "fileTypeDocument"]], "chat_ids": [Int64](),
            "exclude_chat_ids": [Int64](), "return_deleted_file_statistics": false, "chat_limit": 0])
    }
    private func receipt(_ destination: Destination, _ reference: TelegramDocumentReference, kind: ConfirmationKind) throws -> RemoteReceipt {
        RemoteReceipt(destinationID: destination.id, tag: reference.tag, opaqueReference: try ProviderSupport.canonical(reference), kind: kind)
    }
    private func incompleteHistory() -> SafeFailure { SafeFailure(.reconciliation, domain: .tdlib, cause: .incompleteHistory) }
}
