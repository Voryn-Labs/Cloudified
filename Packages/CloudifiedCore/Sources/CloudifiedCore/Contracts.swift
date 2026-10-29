import Foundation
@_exported import CloudifiedDiagnostics

public enum Provider: String, Codable, CaseIterable, Sendable {
    case google, telegram
    public var origin: EventOrigin { self == .google ? .google : .telegram }
}
public enum MediaKind: String, Codable, Sendable { case photo, video }
public enum JobState: String, Codable, Sendable {
    case checking, preparing, ready, uploading, reconciling, delayed, waiting, failed, confirmed
}
public enum ResourceRole: String, Codable, Sendable { case still, motion, video, auxiliary, manifest }
public enum ConfirmationKind: String, Codable, Sendable { case uploaded, alreadyPresent }
/// Demand admission, separate from upload retries. At most one original plan is
/// produced at a time; each lane requests work only when its ready queue is empty.
public protocol SourceWorkProducer: Sendable {
    /// True means the durable source cursor advanced (possibly to a source error).
    func produceNext(for destination: Destination) async throws -> Bool
    /// Plans one more asset only when no planning runs or waits; never queues.
    /// Errors are left for the lane's own planning to meet again.
    func prefetch(for destination: Destination) async -> Bool
}
extension SourceWorkProducer { public func prefetch(for destination: Destination) async -> Bool { false } }
public enum FailureDisposition: String, Codable, Sendable { case retryable, permanent, providerWait, waiting }
public enum RemoteAcceptance: String, Codable, Sendable { case definitelyNotAccepted, unknown }

/// Private ledger identity; verifiedFingerprint is a lowercase SHA-256 of canonical
/// verified account + durable channel identity, never a display name. Credentials
/// live in Keychain/TDLib only.
public struct Destination: Codable, Equatable, Sendable {
    public let id: UUID
    public let provider: Provider
    public let verifiedFingerprint: String
    public init(id: UUID = UUID(), provider: Provider, verifiedFingerprint: String) {
        self.id = id; self.provider = provider; self.verifiedFingerprint = verifiedFingerprint
    }
}

public struct AssetIdentity: Codable, Equatable, Sendable {
    public let id: UUID
    public let localIdentifier: String
    public let generation: String
    public let kind: MediaKind
    public init(id: UUID = UUID(), localIdentifier: String, generation: String, kind: MediaKind) {
        self.id = id; self.localIdentifier = localIdentifier; self.generation = generation; self.kind = kind
    }
}

public struct OriginalContent: Codable, Equatable, Sendable {
    public let sha256: String
    public let sha1: String
    public let byteCount: Int64
    public let role: ResourceRole
    public let partIndex: Int?
    public let partCount: Int?
    public init(sha256: String, sha1: String, byteCount: Int64, role: ResourceRole,
                partIndex: Int? = nil, partCount: Int? = nil) {
        self.sha256 = sha256; self.sha1 = sha1; self.byteCount = byteCount; self.role = role
        self.partIndex = partIndex; self.partCount = partCount
    }
}

/// One remote obligation: original, lossless part, paired originals or archive manifest.
/// tag is a version-1 canonical SHA-256 identity stable across reinstalls. A paired
/// upload contains two originals; a manifest may have no media input. P3 defines
/// canonical content/policy encoding; P4 must put the tag on every Telegram message.
public struct ResourceRequirement: Codable, Equatable, Sendable {
    public let id: UUID
    public let tag: String
    public let role: ResourceRole
    public let originals: [OriginalContent]
    public init(id: UUID = UUID(), tag: String, role: ResourceRole, originals: [OriginalContent]) {
        self.id = id; self.tag = tag; self.role = role; self.originals = originals
    }
}

public struct UploadPlan: Codable, Equatable, Sendable {
    public let coverageHash: String
    public let policyVersion: String
    public let resources: [ResourceRequirement]
    public init(coverageHash: String, policyVersion: String, resources: [ResourceRequirement]) {
        self.coverageHash = coverageHash; self.policyVersion = policyVersion; self.resources = resources
    }
    func validate() throws {
        guard Self.hex(coverageHash, length: 64), !policyVersion.isEmpty, !policyVersion.contains("\0"), policyVersion.utf8.count <= 128,
              !resources.isEmpty, resources.count <= 256,
              Set(resources.map(\.tag)).count == resources.count,
              Set(resources.map(\.id)).count == resources.count else { throw CoreError.invalidContract }
        for resource in resources {
            guard Self.hex(resource.tag, length: 64), resource.originals.count <= 2,
                  resource.role == .manifest || !resource.originals.isEmpty else { throw CoreError.invalidContract }
            for original in resource.originals {
                guard Self.hex(original.sha256, length: 64), Self.hex(original.sha1, length: 40),
                      original.byteCount >= 0 else { throw CoreError.invalidContract }
                if let index = original.partIndex {
                    guard let count = original.partCount, count > 0, index >= 0, index < count else { throw CoreError.invalidContract }
                } else if original.partCount != nil { throw CoreError.invalidContract }
            }
        }
    }
    static func hex(_ value: String, length: Int) -> Bool {
        value.utf8.count == length && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

public struct RemoteReceipt: Codable, Equatable, Sendable {
    public let destinationID: UUID
    public let tag: String
    /// MediaKey/final Telegram message identifiers; private persistence, never logs.
    public let opaqueReference: Data
    public let kind: ConfirmationKind
    public init(destinationID: UUID, tag: String, opaqueReference: Data, kind: ConfirmationKind) {
        self.destinationID = destinationID; self.tag = tag; self.opaqueReference = opaqueReference; self.kind = kind
    }
}
public enum RemotePresence: Sendable {
    case present(RemoteReceipt)
    /// Complete hash/history lookup, same verified destination, all possible pending
    /// transports settled. Lookup error, short history page or HTTP 404 alone is not proof.
    case verifiedAbsent
    case unknown(SafeFailure)
    /// Login/quota/access/flood restriction applies to this destination, not each
    /// pending asset. Pause the lane without spending pending assets' attempts.
    case destinationBlocked(SafeFailure, resumeAt: Date?)
}
public struct UploadFailure: Codable, Sendable {
    public let error: SafeFailure
    public let disposition: FailureDisposition
    public let acceptance: RemoteAcceptance
    public let retryAfter: Date?
    public let didStartTransfer: Bool
    public init(_ error: SafeFailure, disposition: FailureDisposition, acceptance: RemoteAcceptance, retryAfter: Date? = nil,
                didStartTransfer: Bool = true) {
        self.error = error; self.disposition = disposition; self.acceptance = acceptance; self.retryAfter = retryAfter
        self.didStartTransfer = didStartTransfer
    }
}
public enum InputOwnership: Sendable { case terminal, retainedByTransport }
public enum UploadOutcome: Sendable {
    /// A durable OS task owns the input. This is neither failure nor acceptance.
    case submitted
    case confirmed(RemoteReceipt, InputOwnership)
    case failed(UploadFailure, InputOwnership)
}
public struct JobRecord: Sendable {
    public let id: UUID
    public let destination: Destination
    public let asset: AssetIdentity
    public let plan: UploadPlan
    public let state: JobState
    public let cycleID: UUID
    public let attempts: Int
    public let retryAt: Date?
}
public struct TransferProgress: Sendable {
    public let resourceID: UUID
    public let bytes: Int64
    public let expectedBytes: Int64?
    public init(resourceID: UUID, bytes: Int64, expectedBytes: Int64?) {
        self.resourceID = resourceID; self.bytes = bytes; self.expectedBytes = expectedBytes
    }
}
public protocol ProviderAdapter: Sendable {
    var provider: Provider { get }
    /// Backpressure before claiming or measuring another original.
    var canAcceptWork: Bool { get async throws }
    /// The OS keeps the transfer going without the app, so the next original
    /// is worth exporting during this upload.
    var prefetchesNextOriginal: Bool { get }
    func canAdmit(_ job: JobRecord) async throws -> Bool
    func inspect(destination: Destination, resource: ResourceRequirement) async -> RemotePresence
    /// Return terminal only after every file reader/callback is fenced. Background
    /// tasks retain the transferID hold until real OS/TDLib terminal reconciliation.
    /// Cancellation must return classified uncertainty, never fabricate absence.
    func upload(job: JobRecord, resource: ResourceRequirement, files: [LeasedFile], transferID: UUID,
                progress: @escaping @Sendable (TransferProgress) async -> Void) async -> UploadOutcome
}
public protocol OriginalPreparer: Sendable {
    /// Engine serializes this operation across providers. Verify identity again on
    /// re-export, publish only complete originals, return acquired leases, not bare
    /// URLs. Receipts let the final manifest reference previously confirmed parts.
    func prepare(job: JobRecord, resource: ResourceRequirement, receipts: [RemoteReceipt]) async throws -> [LeasedFile]
}
public enum CoreError: Error, Sendable {
    case invalidContract, invalidTransition, recoveryRequired, staleMapping, stagedUnavailable, persistence(Int32)
}

extension ProviderAdapter {
    public func canAdmit(_ job: JobRecord) async throws -> Bool { true }
    public var canAcceptWork: Bool { get async { true } }
    public var prefetchesNextOriginal: Bool { false }
}
