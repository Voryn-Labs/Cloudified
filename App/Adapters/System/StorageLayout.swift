import Foundation
import Darwin
import CloudifiedCore

/// Safe Foundation storage-layout coordinator for app-owned Application Support directories.
/// Directs the persistent SQLite database, original media staging roots.
public final class StorageLayout: Sendable {
    public let rootDirectory: URL
    public let databaseURL: URL
    public let stagingURL: URL

    public init(fileManager: FileManager = .default) throws {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let cloudifiedRoot = appSupport.resolvingSymlinksInPath().appendingPathComponent("Cloudified", isDirectory: true)

        self.rootDirectory = cloudifiedRoot
        self.databaseURL = cloudifiedRoot.appendingPathComponent("ledger.sqlite")
        self.stagingURL = cloudifiedRoot.appendingPathComponent("staging", isDirectory: true)

        try Self.prepareDirectory(cloudifiedRoot, fileManager: fileManager)
        try Self.prepareDirectory(stagingURL, fileManager: fileManager)
    }

    /// Prepares directory with intermediate paths, backup exclusion, and complete file protection.
    /// Throws classified SafeFailure on creation or attribute failure.
    static func prepareDirectory(_ url: URL, fileManager: FileManager) throws {
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else {
            throw SafeFailure(.invariant, domain: .fileSystem, cause: .invalidContract)
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SafeFailure(.sourceUnavailable, domain: .fileSystem, cause: .storagePathConflict)
            }
        } catch {
            if let safe = error as? SafeFailure { throw safe }
            throw Self.classify(error)
        }

        var mutableURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        do {
            try mutableURL.setResourceValues(resourceValues)
        } catch {
            throw Self.classify(error)
        }

        #if os(iOS)
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: url.path
            )
        } catch {
            throw Self.classify(error)
        }
        #endif
    }

    /// Conservative available volume bytes; a purgeable/important-usage estimate
    /// cannot substitute for the physical reserve required by source admission.
    /// Throws classified SafeFailure instead of returning 0 or manufacturing false disk full.
    public func availableCapacity() throws -> Int64 {
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityKey
        ]
        do {
            let values = try rootDirectory.resourceValues(forKeys: keys)
            if let standard = values.volumeAvailableCapacity, standard >= 0 {
                return Int64(standard)
            }
        } catch {
            // Fall through to attributesOfFileSystem
        }

        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: rootDirectory.path)
            if let freeSize = attrs[.systemFreeSize] as? Int64, freeSize >= 0 {
                return freeSize
            }
        } catch {
            throw Self.classify(error)
        }

        throw SafeFailure(.sourceUnavailable, domain: .fileSystem, cause: .unknown)
    }

    private static func classify(_ error: any Error) -> SafeFailure {
        let value = error as NSError
        if (value.domain == NSPOSIXErrorDomain && (value.code == Int(ENOSPC) || value.code == Int(EDQUOT))) ||
            (value.domain == NSCocoaErrorDomain && value.code == NSFileWriteOutOfSpaceError) {
            return SafeFailure(.diskFull, domain: .fileSystem, code: value.code, cause: .insufficientSpace)
        }
        if (value.domain == NSPOSIXErrorDomain && (value.code == Int(EACCES) || value.code == Int(EPERM))) ||
            (value.domain == NSCocoaErrorDomain && (value.code == NSFileReadNoPermissionError || value.code == NSFileWriteNoPermissionError)) {
            return SafeFailure(.accessDenied, domain: .fileSystem, code: value.code, cause: .permissionDenied)
        }
        return SafeFailure(.transfer, domain: .fileSystem, code: value.code, cause: .unknown)
    }
}
