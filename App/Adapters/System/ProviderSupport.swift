import Foundation
import CryptoKit
import CloudifiedCore

struct SafeProviderFailure: Error, Sendable {
    let failure: SafeFailure
    let retryAfter: Date?
    var commitNotSubmitted = false
}
enum ProviderSupport {
    static func coreCase(_ error: any Error) -> DiagnosticCoreError? {
        guard let core = error as? CoreError else { return nil }
        switch core {
        case .invalidContract: return .invalidContract
        case .invalidTransition: return .invalidTransition
        case .recoveryRequired: return .recoveryRequired
        case .staleMapping: return .staleMapping
        case .stagedUnavailable: return .stagedUnavailable
        case .persistence: return .persistence
        }
    }
    static func hashFile(_ url: URL) async throws -> (sha256: String, sha1: String, byteCount: Int64) {
        let work = Task.detached(priority: .utility) { try StreamingFileHasher.hash(fileURL: url) }
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hex(_ text: String, count: Int) throws -> Data {
        guard text.utf8.count == count * 2, text.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CoreError.invalidContract }
        let bytes = Array(text.utf8); var data = Data(); data.reserveCapacity(count)
        func nibble(_ b: UInt8) -> UInt8 { b < 58 ? b - 48 : b - 87 }
        for index in stride(from: 0, to: bytes.count, by: 2) { data.append(nibble(bytes[index]) * 16 + nibble(bytes[index + 1])) }
        return data
    }
    static func safe(_ error: any Error, domain: ErrorDomain) -> SafeFailure {
        if let rejected = error as? TDLibRequestRejection { return rejected.failure }
        if let wrapped = error as? SafeProviderFailure { return wrapped.failure }
        if let safe = error as? SafeFailure { return safe }
        if case CoreError.persistence(let code) = error { return SafeFailure(.invariant, domain: .sqlite, code: Int(code), cause: .persistenceFailed) }
        if let credential = error as? CredentialError {
            switch credential {
            case .notConfigured: return SafeFailure(.authentication, domain: domain, cause: .loginRequired)
            case .accessDenied(let code): return SafeFailure(.accessDenied, domain: domain, code: Int(code), cause: .permissionDenied)
            case .storageFailure(let code): return SafeFailure(.invariant, domain: domain, code: Int(code), cause: .persistenceFailed)
            case .corrupt, .invalidProfile: return SafeFailure(.invariant, domain: domain, cause: .invalidContract)
            }
        }
        if let failure = error as? GoogleTokenExchange.Failure { return failure.failure ?? SafeFailure(.authentication, domain: .google, cause: .loginRequired) }
        if error is TDLibError { return TDLibClient.classify(error) }
        if let error = error as? GPMCError { return GooglePhotosClientSession.classify(error) }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileWriteOutOfSpaceError { return SafeFailure(.diskFull, domain: .fileSystem, code: cocoa.code, cause: .insufficientSpace) }
        if cocoa.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(cocoa.code) { return SafeFailure(.accessDenied, domain: .fileSystem, code: cocoa.code, cause: .permissionDenied) }
        if case CoreError.staleMapping = error { return SafeFailure(.authentication, domain: domain, cause: .accountChanged) }
        if case CoreError.recoveryRequired = error { return SafeFailure(.reconciliation, domain: domain, cause: .outcomeUnknown) }
        if error is CoreError { return SafeFailure(.invariant, domain: .core, cause: .invalidContract) }
        if error is CancellationError { return SafeFailure(.connectivity, domain: domain, cause: .interrupted) }
        if let error = error as? URLError {
            let cause: KnownCause
            switch error.code {
            case .timedOut: cause = .deadlineExceeded
            case .notConnectedToInternet, .networkConnectionLost: cause = .offline
            case .cancelled: cause = .interrupted
            default: cause = .networkRequestFailed
            }
            return SafeFailure(error.code == .timedOut ? .timeout : .connectivity, domain: .urlSession, code: error.errorCode, cause: cause)
        }
        return SafeFailure(.transfer, domain: domain, cause: .unknown)
    }
    static func disposition(_ failure: SafeFailure) -> FailureDisposition {
        if failure.cause == .nativeCapacityExceeded { return .providerWait }
        switch failure.category {
        case .authentication, .accessDenied, .quota, .rateLimit: return .providerWait
        case .invariant, .unsupportedOriginal, .sourceUnavailable: return .permanent
        case .diskFull: return .waiting
        default: return failure.cause == .interrupted ? .waiting : .retryable
        }
    }
    /// Invalid evidence for one resource must not fence every resource. Scope
    /// changes and persistence faults still require destination-level recovery.
    static func blocksDestination(_ error: any Error, domain: ErrorDomain) -> Bool {
        let failure = safe(error, domain: domain)
        if failure.cause == .nativeCapacityExceeded { return true }
        switch failure.category {
        case .authentication, .accessDenied, .quota, .rateLimit: return true
        default: break
        }
        if let core = error as? CoreError {
            switch core {
            case .staleMapping, .persistence: return true
            default: break
            }
        }
        return false
    }
    static func availableBytes(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let bytes = values.volumeAvailableCapacity, bytes >= 0 else { throw CoreError.invalidContract }
        return Int64(bytes)
    }
    static func context(_ job: JobRecord, _ resource: ResourceRequirement) -> EventContext {
        EventContext(origin: job.destination.provider.origin, destinationID: job.destination.id, jobID: job.id,
                     assetID: job.asset.id, resourceID: resource.id, cycleID: job.cycleID, attempt: job.attempts)
    }
}

/// Sync callbacks overwrite one latest sample. Exactly one consumer per active
/// upload; no Task per network chunk. stop() joins before the adapter returns.
final class ProviderProgressPump: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: (Int64, Int64)?
    private var worker: Task<Void, Never>?
    private let resourceID: UUID
    private let report: @Sendable (TransferProgress) async -> Void
    init(resourceID: UUID, report: @escaping @Sendable (TransferProgress) async -> Void) {
        self.resourceID = resourceID; self.report = report
    }
    func offer(_ bytes: Int64, _ total: Int64) {
        guard bytes >= 0, total >= bytes else { return }
        lock.lock(); latest = (bytes, total); lock.unlock()
    }
    private func take() -> (Int64, Int64)? { lock.lock(); defer { lock.unlock() }; let value = latest; latest = nil; return value }
    func start() {
        precondition(worker == nil)
        worker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                guard let self else { return }
                if let value = self.take() { await self.report(TransferProgress(resourceID: self.resourceID, bytes: value.0, expectedBytes: value.1)) }
            }
        }
    }
    func stop() async {
        worker?.cancel(); await worker?.value; worker = nil
        if let value = take() { await report(TransferProgress(resourceID: resourceID, bytes: value.0, expectedBytes: value.1)) }
    }
}
