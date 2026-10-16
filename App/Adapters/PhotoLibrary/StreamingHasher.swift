import Foundation
import Darwin
import CryptoKit
import CloudifiedCore

/// Mutable handles/hashes/terminal state are protected by lock. Callers still fence
/// PhotoKit before ending export ownership and removing any file.
public final class StreamingFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let fileHandle: FileHandle
    private let beforeWrite: (@Sendable (Int64) throws -> Void)?
    private let afterWrite: (@Sendable (Int64) throws -> Void)?
    private var sha256Hasher = SHA256()
    private var sha1Hasher = Insecure.SHA1()
    private var totalBytesWritten: Int64 = 0
    private var isClosed = false
    public init(fileURL: URL, beforeWrite: (@Sendable (Int64) throws -> Void)? = nil,
                afterWrite: (@Sendable (Int64) throws -> Void)? = nil) throws {
        let fd = fileURL.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600)) }
        guard fd >= 0 else { throw Self.safePOSIX(errno) }
        self.fileHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.beforeWrite = beforeWrite
        self.afterWrite = afterWrite
    }
    public func write(chunk: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { throw CoreError.invalidTransition }
        var start = chunk.startIndex
        while start < chunk.endIndex {
            let end = min(start + 1_048_576, chunk.endIndex)
            let slice = chunk[start..<end]
            guard totalBytesWritten <= Int64.max - Int64(slice.count) else { throw CoreError.invalidContract }
            try beforeWrite?(totalBytesWritten + Int64(slice.count))
            do { try fileHandle.write(contentsOf: slice) } catch { throw Self.safe(error) }
            sha256Hasher.update(data: slice); sha1Hasher.update(data: slice)
            totalBytesWritten += Int64(slice.count); start = end
            // Progress is measured only after the complete write/hash succeeds.
            try afterWrite?(totalBytesWritten)
        }
    }
    public func finalize() throws -> (sha256: String, sha1: String, byteCount: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { throw CoreError.invalidTransition }
        // Close even when synchronize fails; no successful result if close fails.
        do {
            try fileHandle.synchronize(); try fileHandle.close(); isClosed = true
        } catch { isClosed = true; try? fileHandle.close(); throw Self.safe(error) }
        return (sha256Hasher.finalize().map { String(format: "%02x", $0) }.joined(),
                sha1Hasher.finalize().map { String(format: "%02x", $0) }.joined(), totalBytesWritten)
    }
    public func abort() {
        lock.lock(); defer { lock.unlock() }
        if !isClosed { isClosed = true; try? fileHandle.close() }
    }
    deinit { if !isClosed { try? fileHandle.close() } }
    private static func safePOSIX(_ code: Int32) -> SafeFailure {
        if code == ENOSPC || code == EDQUOT { return SafeFailure(.diskFull, domain: .fileSystem, code: Int(code), cause: .insufficientSpace) }
        if code == EACCES || code == EPERM { return SafeFailure(.accessDenied, domain: .fileSystem, code: Int(code), cause: .permissionDenied) }
        return SafeFailure(.transfer, domain: .fileSystem, code: Int(code), cause: .unknown)
    }
    private static func safe(_ error: any Error) -> SafeFailure {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain { return safePOSIX(Int32(error.code)) }
        if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteOutOfSpaceError {
            return SafeFailure(.diskFull, domain: .fileSystem, code: error.code, cause: .insufficientSpace)
        }
        return SafeFailure(.transfer, domain: .fileSystem, code: error.code, cause: .unknown)
    }
}
public enum StreamingFileHasher {
    public static func hash(fileURL: URL, chunkSize: Int = 1_048_576) throws -> (sha256: String, sha1: String, byteCount: Int64) {
        guard (1...1_048_576).contains(chunkSize) else { throw CoreError.invalidContract }
        let handle = try FileHandle(forReadingFrom: fileURL); defer { try? handle.close() }
        var sha256 = SHA256(); var sha1 = Insecure.SHA1(); var total: Int64 = 0
        var ended = false
        while !ended {
            try autoreleasepool {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { ended = true; return }
                guard total <= Int64.max - Int64(chunk.count) else { throw CoreError.invalidContract }
                sha256.update(data: chunk); sha1.update(data: chunk); total += Int64(chunk.count)
            }
        }
        return (sha256.finalize().map { String(format: "%02x", $0) }.joined(),
                sha1.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }
}
