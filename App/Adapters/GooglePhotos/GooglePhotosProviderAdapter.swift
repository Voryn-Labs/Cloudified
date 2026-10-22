import Foundation
import CloudifiedCore

/// Original/non-quota wire behavior comes from pinned PhotosBackup. This actor
/// adds verified account scope and durable evidence; it never retries an asset.
actor GooglePhotosProviderAdapter: ProviderAdapter {
    nonisolated let provider = Provider.google
    nonisolated var prefetchesNextOriginal: Bool { false }
    private static let queueLimit = 4
    private static let queueBytes: Int64 = 64 * 1024 * 1024
    private struct Scope: Codable, Equatable { let version: Int; let subject: String }
    private struct State: Codable {
        var prepared: [PreparedUpload?]
        var mediaKeys: [String?]
        var commitIndex: Int?
        // Optional for old checkpoints. Legacy prepared states with a key are
        // conservatively treated as uploaded, never as proof of rejection.
        var didUpload: Bool?
    }
    let session: GooglePhotosClientSession
    let ledger: Ledger
    private let files: FileLeaseStore
    private let background: BackgroundFileUploadTransport?
    private var destination: Destination?
    private var busy = false
    let catalogURL: URL?
    var catalog: GoogleRemoteIndex?
    var catalogRetry = Date.distantPast
    var catalogScope: String?
    init(session: GooglePhotosClientSession, ledger: Ledger, files: FileLeaseStore, background: BackgroundFileUploadTransport? = nil, catalogURL: URL? = nil) {
        self.session = session; self.ledger = ledger; self.files = files; self.background = background; self.catalogURL = catalogURL
    }
    var canAcceptWork: Bool {
        get async {
            guard let destination = try? await ledger.selectedDestination(.google) else { return false }
            return (try? await queuedBytes(destination)) != nil
        }
    }
    /// Inventoried single-original readers and unreadable results retain exact
    /// queue/storage budgets. Other terminal, oversized or paired work must settle.
    private func queuedBytes(_ requested: Destination) async throws -> Int64? {
        let retained = try await ledger.retainedTransfers(destinationID: requested.id, limit: 8)
        guard retained.count < Self.queueLimit else { return nil }
        if let background {
            let readers = try await background.activeTransferIDs()
            guard readers.isSubset(of: Set(retained.map(\.id))) else { return nil }
        }
        guard !retained.isEmpty else { return 0 }
        guard let background, background.continuesAfterProcessExit else { return nil }
        let inventory = try await background.inventories(Set(retained.map(\.id)))
        var bytes: Int64 = 0
        for transfer in retained {
            guard transfer.resource.originals.count == 1,
                  let checkpoint = try await ledger.providerCheckpoint(destinationID: requested.id, tag: transfer.resource.tag),
                  checkpoint.transferID == transfer.id, checkpoint.jobID == transfer.job.id,
                  checkpoint.phase == .transferring, !checkpoint.inputsTerminal,
                  let status = inventory[transfer.id] else { return nil }
            switch status {
            case .active, .unavailable: break // Both keep their exact input and queue budget.
            default: return nil
            }
            let size = transfer.resource.originals[0].byteCount
            guard size >= 0, size <= Self.queueBytes - bytes else { return nil }
            bytes += size
        }
        return bytes
    }
    func canAdmit(_ job: JobRecord) async throws -> Bool {
        guard !busy, let bytes = try await queuedBytes(job.destination) else { return false }
        if bytes == 0, try await ledger.retainedTransfers(destinationID: job.destination.id, limit: 1).isEmpty { return true }
        guard job.plan.resources.count == 1, let resource = job.plan.resources.first,
              resource.originals.count == 1 else { return false }
        let size = resource.originals[0].byteCount
        return size >= 0 && size <= Self.queueBytes - bytes
    }
    func cancelOwnedTransfers() async throws {
        guard let background else { return }
        var cursor: UUID?
        while true {
            let page = try await ledger.destinationInventoryPage(afterID: cursor)
            if page.isEmpty { break }
            for row in page where row.destination.provider == .google && row.retainedTransferCount > 0 {
                for transfer in try await ledger.retainedTransfers(destinationID: row.destination.id, limit: 8) {
                    await background.cancel(transferID: transfer.id)
                }
            }
            cursor = page.last?.destination.id
        }
    }
    func backgroundTransferSnapshot() async throws -> [(JobRecord, ResourceRequirement, Int64, Int64)] {
        guard let background, let selected = try await ledger.selectedDestination(.google) else { return [] }
        var result: [(JobRecord, ResourceRequirement, Int64, Int64)] = []
        let transfers = try await ledger.retainedTransfers(destinationID: selected.id, limit: 8)
        let inventory = try await background.inventories(Set(transfers.map(\.id)))
        for transfer in transfers {
            if case .active(let sent, let total)? = inventory[transfer.id] {
                result.append((transfer.job, transfer.resource, sent, total))
            }
        }
        return result
    }
    /// Call after loading/connecting the actual credential. Settings must settle
    /// the previous mapping before switching the session's credential.
    func mapVerifiedAccount() async throws -> Destination {
        guard !busy else { throw CoreError.invalidTransition }; busy = true; defer { busy = false }
        let scope = try await verifiedScope()
        try await session.validateReadAccess()
        let mapped = try await ledger.selectDestination(Destination(provider: .google, verifiedFingerprint: ProviderSupport.fingerprint(scope)))
        try await ledger.bindProviderProfile(destination: mapped, profileID: session.profileID, scope: scope)
        destination = mapped
        return mapped
    }
    private func verifiedScope() async throws -> Data {
        try ProviderSupport.canonical(Scope(version: 1, subject: await session.verifiedSubject()))
    }
    func verify(_ requested: Destination) async throws {
        guard requested.provider == .google else { throw CoreError.staleMapping }
        let scope = try await verifiedScope()
        guard ProviderSupport.fingerprint(scope) == requested.verifiedFingerprint,
              let binding = try await ledger.providerBinding(destinationID: requested.id),
              binding.profileID == session.profileID, binding.scope == scope else { throw CoreError.staleMapping }
        // Background transport ownership must be backed by a real OS inventory.
        guard !(await session.usesBackgroundTransfers) || background != nil else { throw CoreError.recoveryRequired }
        destination = requested
    }
    /// Foreground readers cannot survive process death. This is not proof that a
    /// commit was rejected: ambiguous finalization checkpoints remain uncertain.
    func recover(_ requested: Destination) async throws {
        guard !busy else { throw CoreError.invalidTransition }; busy = true; defer { busy = false }
        try await verify(requested)
        let owned = try await settleInputs(requested, finalize: true)
        try await session.validateReadAccess()
        try await ledger.completeDestinationRecovery(requested.id, inventoriedLiveTransfers: owned)
    }
    /// Local crash inventory only: foreground readers are gone without needing
    /// a remote login. Unknown commits remain uncertain and account recovery stays
    /// incomplete until the real credential/remote checks succeed.
    func inventoryInputs(_ requested: Destination) async throws {
        guard !busy, requested.provider == .google else { throw CoreError.recoveryRequired }
        busy = true; defer { busy = false }
        _ = try await settleInputs(requested, finalize: false)
    }
    private func settleInputs(_ requested: Destination, finalize: Bool) async throws -> Set<UUID> {
        var cursor: UUID?, owned: Set<UUID> = []
        while true {
            let page = try await ledger.retainedTransfers(destinationID: requested.id, afterID: cursor)
            if page.isEmpty { break }
            for transfer in page {
                cursor = transfer.id
                guard let checkpoint = try await ledger.providerCheckpoint(destinationID: requested.id, tag: transfer.resource.tag) else {
                    // No checkpoint => no submission fence. Still ask the OS.
                    if let background {
                        guard case .absent = try await background.inventory(transfer.id) else { throw CoreError.recoveryRequired }
                    }
                    try await files.transportFinished(transfer.id); continue
                }
                let inventory = try await background?.inventory(transfer.id) ?? .absent
                let stage: DiagnosticStage
                let failure: SafeFailure?
                switch inventory {
                case .active: stage = .googleTransferActive; failure = nil
                case .completed: stage = .googleTransferCompleted; failure = nil
                case .absent: stage = .googleTransferAbsent; failure = nil
                case .failed(let value), .unavailable(let value, _): stage = .googleTransferFailed; failure = value
                }
                let context = EventContext(origin: .google, destinationID: requested.id, jobID: transfer.job.id, resourceID: transfer.resource.id,
                    diagnostic: DiagnosticDetail(stage: stage, status: failure == nil ? .changed : .failed, correlationID: transfer.id))
                try await ledger.appendEvent(.setupTrace, context: context, decision: .reconcile, severity: failure == nil ? .info : .warning, failure: failure)
                if case .active = inventory { owned.insert(transfer.id); continue }
                var unreadableResult: SafeFailure?
                if case .unavailable(let failure, let readerActive) = inventory, !readerActive { unreadableResult = failure }
                if case .unavailable(let failure, let readerActive) = inventory, readerActive {
                    owned.insert(transfer.id)
                    if transfer.job.state != .waiting && transfer.job.state != .failed {
                        try await ledger.failAttempt(jobID: transfer.job.id,
                            failure: UploadFailure(failure, disposition: .waiting, acceptance: .unknown, didStartTransfer: false),
                            resourceID: transfer.resource.id, transferID: transfer.id)
                    }
                    continue
                }
                if !finalize {
                    switch inventory {
                    case .completed, .failed: owned.insert(transfer.id); continue
                    default: break
                    }
                }
                var state = try decoded(checkpoint, resource: transfer.resource)
                var phase = checkpoint.phase
                if case .completed(let result) = inventory, phase == .transferring {
                    guard state.prepared.count == transfer.resource.originals.count,
                          state.mediaKeys.count == transfer.resource.originals.count,
                          let index = state.prepared.indices.first(where: { state.prepared[$0] != nil && state.mediaKeys[$0] == nil }),
                          let prepared = state.prepared[index],
                          prepared.byteCount == transfer.resource.originals[index].byteCount,
                          prepared.hash == (try ProviderSupport.hex(transfer.resource.originals[index].sha1, count: 20)),
                          prepared.uploadURL.scheme == "https", prepared.uploadURL.host == "photos.googleapis.com" else { throw CoreError.invalidContract }
                    let received: PreparedUpload
                    do { received = try await session.recoveredTransfer(prepared, result: result) }
                    catch {
                        let safe = ProviderSupport.safe(error, domain: .google)
                        try await save(transfer.job.id, requested, transfer.resource, transfer.id,
                            state.mediaKeys.contains(where: { $0 != nil }) ? .partial : .rejected, state)
                        try await ledger.failAttempt(jobID: transfer.job.id, failure: UploadFailure(safe, disposition: ProviderSupport.disposition(safe), acceptance: .definitelyNotAccepted,
                            retryAfter: (error as? SafeProviderFailure)?.retryAfter), resourceID: transfer.resource.id, transferID: transfer.id)
                        try await files.transportFinished(transfer.id); await background?.forget(transferID: transfer.id)
                        if ProviderSupport.blocksDestination(error, domain: .google) || error is CancellationError { throw error }
                        continue
                    }
                    state.prepared[index] = received; state.commitIndex = index
                    state.didUpload = true
                    try await save(transfer.job.id, requested, transfer.resource, transfer.id, .committing, state)
                    // Durable fence precedes RPC; a crash here remains uncertain.
                    do {
                        let outcome = try await session.commit(prepared: received, useQuota: false, saver: false,
                            pairedStillHash: transfer.resource.originals.count == 2 && index == 1 ? ProviderSupport.hex(transfer.resource.originals[0].sha1, count: 20) : nil, phase: { _ in })
                        state.mediaKeys[index] = outcome.mediaKey; state.commitIndex = nil
                    } catch {
                        // The OS transfer is terminal here; only commit acceptance
                        // is unknown. Retain that fence without retaining a reader
                        // or preventing the next asset from being checked.
                        let safe = ProviderSupport.safe(error, domain: .google)
                        try await save(transfer.job.id, requested, transfer.resource, transfer.id, .uncertain, state)
                        try await ledger.failAttempt(jobID: transfer.job.id,
                            failure: UploadFailure(safe, disposition: ProviderSupport.disposition(safe), acceptance: .unknown,
                                retryAfter: (error as? SafeProviderFailure)?.retryAfter, didStartTransfer: false),
                            resourceID: transfer.resource.id, transferID: transfer.id)
                        try await files.transportFinished(transfer.id); await background?.forget(transferID: transfer.id)
                        if ProviderSupport.blocksDestination(error, domain: .google) || error is CancellationError { throw error }
                        continue
                    }
                    state.prepared[index] = nil; state.didUpload = true
                    phase = .partial
                } else if case .failed(let failure) = inventory, phase == .transferring {
                    phase = state.mediaKeys.contains(where: { $0 != nil }) ? .partial : .rejected
                    try await save(transfer.job.id, requested, transfer.resource, transfer.id, phase, state)
                    try await ledger.failAttempt(jobID: transfer.job.id, failure: UploadFailure(failure, disposition: ProviderSupport.disposition(failure), acceptance: .definitelyNotAccepted, didStartTransfer: failure.cause != .interrupted), resourceID: transfer.resource.id, transferID: transfer.id)
                } else {
                    switch phase {
                    case .prepared, .transferring:
                        phase = state.mediaKeys.contains(where: { $0 != nil }) ? .partial : .rejected
                    case .committing, .uncertain: phase = .uncertain
                    case .confirmed, .rejected, .partial: break
                    }
                }
                try await save(transfer.job.id, requested, transfer.resource, transfer.id, phase, state)
                if let receipt = try acceptedReceipt(requested, transfer.resource, state) {
                    try await save(transfer.job.id, requested, transfer.resource, transfer.id, .confirmed, state)
                    try await ledger.confirm(receipt, jobID: transfer.job.id, resourceID: transfer.resource.id)
                } else if try await ledger.job(transfer.job.id).state == .uploading || unreadableResult != nil {
                    // Reclaim a submitted job after a crash between checkpoint
                    // writes. Only committing/uncertain phases fence acceptance.
                    let uncertain = phase == .committing || phase == .uncertain
                    try await ledger.failAttempt(jobID: transfer.job.id,
                        failure: UploadFailure(unreadableResult ?? SafeFailure(uncertain ? .reconciliation : .connectivity,
                            domain: .google, cause: uncertain ? .outcomeUnknown : .interrupted),
                            disposition: unreadableResult != nil && !uncertain ? .retryable : .waiting,
                            acceptance: uncertain ? .unknown : .definitelyNotAccepted,
                            didStartTransfer: unreadableResult != nil && checkpoint.phase == .transferring),
                        resourceID: transfer.resource.id, transferID: transfer.id)
                }
                try await files.transportFinished(transfer.id)
                await background?.forget(transferID: transfer.id)
                try await ledger.wakeWaiting(destinationID: requested.id)
            }
        }
        return owned
    }
    func inspect(destination requested: Destination, resource: ResourceRequirement) async -> RemotePresence {
        guard !busy else { return .unknown(SafeFailure(.reconciliation, domain: .google, cause: .outcomeUnknown)) }
        busy = true; defer { busy = false }
        do {
            try await verify(requested)
            let checkpoint = try await ledger.providerCheckpoint(destinationID: requested.id, tag: resource.tag)
            if let checkpoint, let receipt = try acceptedReceipt(requested, resource, decoded(checkpoint, resource: resource)) {
                let state = try decoded(checkpoint, resource: resource)
                try await save(checkpoint.jobID, requested, resource, checkpoint.transferID, .confirmed, state)
                return .present(receipt)
            }
            let keys = try await remoteKeys(resource)
            if let keys {
                await libraryEvent(.googleHashMatch, requested)
                let previous = try checkpoint.map { try decoded($0, resource: resource) }
                let knownUpload = previous.map { $0.didUpload ?? $0.mediaKeys.contains(where: { $0 != nil }) } ?? false
                let receipt = try makeReceipt(requested, resource, keys, kind: knownUpload ? .uploaded : .alreadyPresent)
                if let old = try await ledger.providerCheckpoint(destinationID: requested.id, tag: resource.tag) {
                    let state = State(prepared: Array(repeating: nil, count: keys.count), mediaKeys: keys.map(Optional.some), didUpload: knownUpload)
                    try await save(old.jobID, requested, resource, old.transferID, .confirmed, state)
                }
                return .present(receipt)
            }
            var acceptedOriginals = Set<String>()
            if let checkpoint {
                var state = try decoded(checkpoint, resource: resource)
                switch checkpoint.phase {
                case .confirmed:
                    return .unknown(SafeFailure(.reconciliation, domain: .google, cause: .outcomeUnknown))
                case .committing, .uncertain:
                    guard let index = state.commitIndex, resource.originals.indices.contains(index),
                          state.mediaKeys.count == resource.originals.count else { return .unknown(SafeFailure(.reconciliation, domain: .google, cause: .outcomeUnknown)) }
                    if state.mediaKeys[index] == nil {
                        guard let key = try await session.checkPresence(sha1: ProviderSupport.hex(resource.originals[index].sha1, count: 20), asLivePhotoMotion: resource.originals.count == 2 && index == 1) else { return .unknown(SafeFailure(.reconciliation, domain: .google, cause: .outcomeUnknown)) }
                        state.mediaKeys[index] = key
                    }
                    state.commitIndex = nil; state.prepared[index] = nil
                    state.didUpload = true
                case .transferring:
                    // An unsettled OS transfer is not absence, even if a hash
                    // lookup currently misses. Recovery owns its inventory.
                    return .unknown(SafeFailure(.reconciliation, domain: .google, cause: .outcomeUnknown))
                case .prepared, .rejected, .partial: break
                }
                if let receipt = try acceptedReceipt(requested, resource, state) {
                    try await save(checkpoint.jobID, requested, resource, checkpoint.transferID, .confirmed, state)
                    return .present(receipt)
                }
                if state.mediaKeys.allSatisfy({ $0 != nil }) {
                    return .unknown(SafeFailure(.reconciliation, domain: .google, cause: .pairingUnverified))
                }
                acceptedOriginals = Set(zip(resource.originals, state.mediaKeys).compactMap { $0.1 == nil ? nil : $0.0.sha256 })
                let phase: ProviderCheckpointPhase = state.mediaKeys.contains(where: { $0 != nil }) ? .partial : .rejected
                try await save(checkpoint.jobID, requested, resource, checkpoint.transferID, phase, state)
            }
            if let failure = try await checkLibraryCandidate(requested, resource: resource, acceptedOriginals: acceptedOriginals) { return .unknown(failure) }
            await libraryEvent(.googleHashMiss, requested)
            return .verifiedAbsent
        } catch { return presenceFailure(error) }
    }
    private func remoteKeys(_ resource: ResourceRequirement) async throws -> [String]? {
        guard resource.role != .manifest, (1...2).contains(resource.originals.count) else { throw CoreError.invalidContract }
        var keys: [String] = []
        for (index, content) in resource.originals.enumerated() {
            let key = try await session.checkPresence(sha1: ProviderSupport.hex(content.sha1, count: 20),
                                                     asLivePhotoMotion: resource.originals.count == 2 && index == 1)
            guard let key else { return nil }
            guard !key.isEmpty, key.utf8.count <= 2048 else { throw CoreError.invalidContract }; keys.append(key)
        }
        // A motion hash existing somewhere is insufficient to establish pairing
        // with this still. Require the same final media identity for both hashes.
        if keys.count == 2, keys[0] != keys[1] {
            throw SafeFailure(.reconciliation, domain: .google, cause: .pairingUnverified)
        }
        return keys
    }
    func upload(job: JobRecord, resource: ResourceRequirement, files inputs: [LeasedFile], transferID: UUID,
                progress: @escaping @Sendable (TransferProgress) async -> Void) async -> CloudifiedCore.UploadOutcome {
        guard !busy else { return .failed(UploadFailure(SafeFailure(.invariant, domain: .core, cause: .invalidContract), disposition: .waiting, acceptance: .definitelyNotAccepted, didStartTransfer: false), .terminal) }
        busy = true; defer { busy = false }
        let pump = ProviderProgressPump(resourceID: resource.id, report: progress); pump.start()
        var state = State(prepared: Array(repeating: nil, count: resource.originals.count), mediaKeys: Array(repeating: nil, count: resource.originals.count), didUpload: false)
        var commitSubmitted = false
        var wroteCheckpoint = false
        var didStartTransfer = false
        do {
            try await verify(job.destination)
            guard inputs.count == resource.originals.count, (1...2).contains(inputs.count), resource.role != .manifest,
                  resource.originals.allSatisfy({ $0.partIndex == nil }) else {
                throw SafeFailure(.unsupportedOriginal, domain: .google, cause: .formatRejected)
            }
            if inputs.count == 2 {
                guard resource.originals[0].role == .still, resource.originals[1].role == .motion else { throw CoreError.invalidContract }
            }
            if let old = try await ledger.providerCheckpoint(destinationID: job.destination.id, tag: resource.tag) {
                guard old.inputsTerminal, old.phase == .rejected || old.phase == .partial else {
                    throw SafeFailure(.reconciliation, domain: .google, cause: .outcomeUnknown)
                }
                state = try decoded(old, resource: resource)
                guard state.commitIndex == nil else { throw CoreError.recoveryRequired }
            }
            let overhead = inputs.reduce(Int64(0)) { $0 + $1.byteCount }
            try await ledger.reserveTransport(transferID, bytes: overhead, availableBytes: ProviderSupport.availableBytes(at: inputs[0].url))
            guard let recipeData = try await ledger.sourceRecipe(assetID: job.asset.id) else { throw CoreError.invalidContract }
            let recipe = try JSONDecoder().decode(SourceRecipe.self, from: recipeData); try recipe.validate()
            try await save(job.id, job.destination, resource, transferID, .prepared, state); wroteCheckpoint = true
            var completedBytes: Int64 = 0
            let total = inputs.reduce(Int64(0)) { $0 + $1.byteCount }
            for (index, input) in inputs.enumerated() {
                try Task.checkCancellation()
                if state.mediaKeys[index] != nil {
                    completedBytes += input.byteCount
                    continue // This component already has acceptance evidence.
                }
                let original = resource.originals[index]
                let integrityStarted = ProcessInfo.processInfo.systemUptime
                let measured = try await ProviderSupport.hashFile(input.url)
                try? await ledger.appendEvent(.setupTrace, context: EventContext(origin: provider.origin,
                    destinationID: job.destination.id, jobID: job.id, resourceID: resource.id,
                    diagnostic: DiagnosticDetail(stage: .originalIntegrityCheck, status: .succeeded, correlationID: transferID)),
                    decision: .proceed, duration: ProcessInfo.processInfo.systemUptime - integrityStarted, bytes: measured.byteCount)
                guard measured.sha256 == original.sha256, measured.sha1 == original.sha1,
                      measured.byteCount == original.byteCount, input.byteCount == original.byteCount,
                      let descriptor = recipe.resources.first(where: { $0.originalContent == original }) else { throw CoreError.invalidContract }
                let base = completedBytes
                let phase: @Sendable (UploadPhase) -> Void = { value in
                    if case .sending(let bytes, _) = value { pump.offer(base + bytes, total) }
                }
                let preparation = try await session.prepareVerifiedUpload(file: input.url, filename: descriptor.originalFilename,
                    modified: recipe.metadata.creationDate ?? recipe.metadata.modificationDate,
                    hash: ProviderSupport.hex(original.sha1, count: 20), byteCount: original.byteCount,
                    stillHash: inputs.count == 2 && index == 1 ? ProviderSupport.hex(resource.originals[0].sha1, count: 20) : nil, phase: phase)
                switch preparation {
                case .alreadyBackedUp(let key):
                    state.mediaKeys[index] = key
                    try await save(job.id, job.destination, resource, transferID, .prepared, state)
                case .ready(let prepared):
                    guard prepared.hash == (try ProviderSupport.hex(original.sha1, count: 20)), prepared.byteCount == original.byteCount else { throw CoreError.invalidContract }
                    state.prepared[index] = prepared
                    try await save(job.id, job.destination, resource, transferID, .transferring, state)
                    try Task.checkCancellation()
                    didStartTransfer = true
                    if inputs.count == 1, job.plan.resources.count == 1, input.byteCount <= Self.queueBytes,
                       background?.continuesAfterProcessExit == true {
                        try await session.submit(prepared: prepared, file: input.url, transferID: transferID)
                        await pump.stop()
                        return .submitted
                    }
                    let received = try await session.transfer(prepared: prepared, file: input.url, transferID: transferID, phase: phase)
                    state.prepared[index] = received
                    state.commitIndex = index
                    state.didUpload = true
                    // Write receipt and committing fence BEFORE submitting RPC.
                    try await save(job.id, job.destination, resource, transferID, .committing, state)
                    commitSubmitted = true
                    let result = try await session.commit(prepared: received, useQuota: false, saver: false,
                        pairedStillHash: inputs.count == 2 && index == 1 ? ProviderSupport.hex(resource.originals[0].sha1, count: 20) : nil, phase: phase)
                    state.mediaKeys[index] = result.mediaKey
                    state.prepared[index] = nil; state.commitIndex = nil; state.didUpload = true
                    try await save(job.id, job.destination, resource, transferID, .prepared, state)
                    commitSubmitted = false
                    await session.forgetTransfer(transferID)
                }
                completedBytes += input.byteCount; pump.offer(completedBytes, total)
            }
            // Returned commit keys are durable evidence even before hash search
            // catches up. A pair still requires one common media identity.
            var receipt = try acceptedReceipt(job.destination, resource, state)
            // Pair finalization may remap the still's earlier media key. Accept
            // a common current identity from hash lookup, never resend either
            // accepted component merely because their initial keys differ.
            if receipt == nil, let keys = try await remoteKeys(resource) {
                state.mediaKeys = keys.map(Optional.some)
                receipt = try acceptedReceipt(job.destination, resource, state)
            }
            guard let receipt else {
                throw SafeFailure(.finalization, domain: .google,
                    cause: inputs.count == 2 ? .pairingUnverified : .outcomeUnknown)
            }
            try await save(job.id, job.destination, resource, transferID, .confirmed, state)
            await pump.stop()
            return .confirmed(receipt, .terminal)
        } catch {
            let safe = ProviderSupport.safe(error, domain: .google)
            if wroteCheckpoint, let background {
                do {
                    switch try await background.inventory(transferID) {
                    case .active, .completed, .failed, .unavailable:
                        await pump.stop()
                        return .failed(UploadFailure(safe, disposition: .waiting, acceptance: .unknown), .retainedByTransport)
                    case .absent: break // No OS reader/result to retain or wake us.
                    }
                } catch {
                    await pump.stop()
                    return .failed(UploadFailure(ProviderSupport.safe(error, domain: .google), disposition: .waiting, acceptance: .unknown), .retainedByTransport)
                }
            }
            if wroteCheckpoint {
                let phase: ProviderCheckpointPhase = commitSubmitted && state.commitIndex != nil ? .uncertain :
                    (state.mediaKeys.contains(where: { $0 != nil }) ? .partial : .rejected)
                do { try await save(job.id, job.destination, resource, transferID, phase, state) }
                catch { await pump.stop(); return .failed(UploadFailure(ProviderSupport.safe(error, domain: .google), disposition: .waiting, acceptance: .unknown), .terminal) }
            }
            await session.forgetTransfer(transferID)
            await pump.stop()
            let preSendWait = !didStartTransfer && !commitSubmitted && (safe.category == .connectivity || safe.category == .timeout)
            return .failed(UploadFailure(safe, disposition: preSendWait ? .waiting : ProviderSupport.disposition(safe),
                           acceptance: commitSubmitted || safe.category == .reconciliation ? .unknown : .definitelyNotAccepted,
                           retryAfter: (error as? SafeProviderFailure)?.retryAfter, didStartTransfer: didStartTransfer && safe.cause != .interrupted), .terminal)
        }
    }
    private func decoded(_ checkpoint: ProviderCheckpoint, resource: ResourceRequirement) throws -> State {
        var state = try JSONDecoder().decode(State.self, from: checkpoint.payload)
        guard state.prepared.count == resource.originals.count, state.mediaKeys.count == resource.originals.count,
              state.mediaKeys.allSatisfy({ $0.map { !$0.isEmpty && $0.utf8.count <= 2048 } ?? true }),
              state.commitIndex.map({ resource.originals.indices.contains($0) }) ?? true else { throw CoreError.invalidContract }
        // Older foreground code left commitIndex pointing at an accepted component
        // even in prepared/rejected states. Its key is evidence, not a pending RPC.
        if checkpoint.phase == .prepared || checkpoint.phase == .rejected || checkpoint.phase == .partial,
           let index = state.commitIndex, state.mediaKeys[index] != nil {
            state.commitIndex = nil; state.prepared[index] = nil
        }
        return state
    }
    private func acceptedReceipt(_ destination: Destination, _ resource: ResourceRequirement, _ state: State) throws -> RemoteReceipt? {
        guard resource.role != .manifest, (1...2).contains(resource.originals.count) else { throw CoreError.invalidContract }
        let keys = state.mediaKeys.compactMap { $0 }
        guard keys.count == resource.originals.count else { return nil }
        if keys.count == 2, keys[0] != keys[1] {
            return nil
        }
        return try makeReceipt(destination, resource, keys,
            kind: state.didUpload == false ? .alreadyPresent : .uploaded)
    }
    private func save(_ jobID: UUID, _ destination: Destination, _ resource: ResourceRequirement,
                      _ transfer: UUID, _ phase: ProviderCheckpointPhase, _ state: State) async throws {
        try await ledger.saveProviderCheckpoint(ProviderCheckpoint(destinationID: destination.id, tag: resource.tag,
            transferID: transfer, jobID: jobID, phase: phase, inputsTerminal: phase != .transferring, payload: ProviderSupport.canonical(state)))
    }
    private func makeReceipt(_ destination: Destination, _ resource: ResourceRequirement, _ keys: [String], kind: ConfirmationKind) throws -> RemoteReceipt {
        guard keys.count == resource.originals.count, keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 2048 }) else { throw CoreError.invalidContract }
        return RemoteReceipt(destinationID: destination.id, tag: resource.tag, opaqueReference: try ProviderSupport.canonical(keys), kind: kind)
    }
    private func presenceFailure(_ error: any Error) -> RemotePresence {
        let safe = ProviderSupport.safe(error, domain: .google)
        if ProviderSupport.blocksDestination(error, domain: .google) {
            return .destinationBlocked(safe, resumeAt: (error as? SafeProviderFailure)?.retryAfter)
        }
        return .unknown(safe)
    }
}
