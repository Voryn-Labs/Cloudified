import Foundation
import CloudifiedCore

/// TDLib derives a document filename from its input path. A protected hard link
/// preserves the actual name without copying a large original. Durable checkpoints
/// and Core holds own BOTH path names until all native readers are terminal.
struct TelegramInputFiles: Sendable {
    let root: URL
    init(stagingRoot: URL) { root = stagingRoot.appendingPathComponent("telegram-inputs", isDirectory: true) }
    func url(transferID: UUID, filename: String) throws -> URL {
        guard !filename.isEmpty, filename != ".", filename != "..", filename.utf8.count <= 255,
              !filename.contains("/"), !filename.contains("\\"), !filename.contains("\0") else { throw CoreError.invalidContract }
        return root.appendingPathComponent(transferID.uuidString, isDirectory: true).appendingPathComponent(filename)
    }
    // The transfer UUID and complete app-relative path are the durable identity.
    // TDLib can restore different file/message IDs after a restart; permit only
    // the iOS container UUID (and /private alias) to differ, never the input path.
    static func matchesOwnedPath(_ actual: String, expected: String) -> Bool {
        if actual == expected { return true }
        func containerRelative(_ path: String) -> [String]? {
            guard path.hasPrefix("/"), !path.contains("//") else { return nil }
            var parts = path.split(separator: "/").map(String.init)
            if parts.first == "private" { parts.removeFirst() }
            guard parts.count > 8, Array(parts.prefix(5)) == ["var", "mobile", "Containers", "Data", "Application"],
                  UUID(uuidString: parts[5]) != nil, !parts.contains(".."), !parts.contains("."),
                  let input = parts.firstIndex(of: "telegram-inputs"), input > 5,
                  parts.count == input + 3, UUID(uuidString: parts[input + 1]) != nil else { return nil }
            parts[5] = "<container>"
            return parts
        }
        guard let actualParts = containerRelative(actual), let expectedParts = containerRelative(expected) else { return false }
        return actualParts == expectedParts
    }
    func create(transferID: UUID, input: LeasedFile, filename: String) throws -> URL {
        let target = try url(transferID: transferID, filename: filename)
        guard root.resolvingSymlinksInPath().path == root.standardizedFileURL.path else { throw CoreError.invalidContract }
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard parent.resolvingSymlinksInPath().path == parent.standardizedFileURL.path else { throw CoreError.invalidContract }
        var protected = root
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try protected.setResourceValues(values)
        #if os(iOS)
        for dir in [root, parent] { try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path) }
        #endif
        guard !FileManager.default.fileExists(atPath: target.path), input.url.resolvingSymlinksInPath().path == input.url.standardizedFileURL.path else { throw CoreError.invalidContract }
        try FileManager.default.linkItem(at: input.url, to: target)
        return target
    }
    func remove(transferID: UUID) throws {
        let directory = root.appendingPathComponent(transferID.uuidString, isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw CoreError.invalidContract }
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
    /// Quarantine may admit unrelated work only while this exact input remains
    /// protected. Missing/changed paths never become permission to resend it.
    func verifyProtected(transferID: UUID, filename: String, byteCount: Int64) throws {
        let target = try url(transferID: transferID, filename: filename)
        guard target.resolvingSymlinksInPath().path == target.standardizedFileURL.path else { throw CoreError.invalidContract }
        let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard byteCount > 0, values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize.flatMap(Int64.init(exactly:)) == byteCount else { throw CoreError.invalidContract }
    }
}
