import Foundation
import CloudifiedCore

actor DiagnosticExportStore {
    private let root: URL
    private var active: Set<URL> = []
    init(layout: StorageLayout) throws {
        root = layout.rootDirectory.appendingPathComponent("exports", isDirectory: true)
        guard root.resolvingSymlinksInPath() == root.standardizedFileURL else { throw CoreError.invalidContract }
        try StorageLayout.prepareDirectory(root, fileManager: .default)
    }
    func export(ledger: Ledger) async throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString + ".jsonl")
        active.insert(url)
        do { try await ledger.exportDiagnostics(to: url); return url }
        catch { active.remove(url); try? FileManager.default.removeItem(at: url); throw error }
    }
    func release(_ url: URL) throws {
        guard active.remove(url) != nil else { return }
        try FileManager.default.removeItem(at: url)
    }
    /// Only old exact UUID export files in our canonical directory, <=100 entries.
    func removeStale(now: Date = Date()) throws {
        guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey], options: [.skipsSubdirectoryDescendants]) else { return }
        var firstError: (any Error)?
        for _ in 0..<100 {
            guard let url = iterator.nextObject() as? URL else { break }
            guard !active.contains(url), url.pathExtension == "jsonl",
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  url.lastPathComponent == id.uuidString + ".jsonl" else { continue }
            do {
                let values = try url.resourceValues(forKeys: [.creationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let created = values.creationDate, now.timeIntervalSince(created) > 86_400 else { continue }
                try FileManager.default.removeItem(at: url)
            } catch { if firstError == nil { firstError = error } }
        }
        if let firstError { throw firstError }
    }
}
