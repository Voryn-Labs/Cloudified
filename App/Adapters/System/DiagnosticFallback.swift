import Foundation
import CloudifiedCore
import os

struct DiagnosticFallbackEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let timestamp: Date
    let failure: SafeFailure
}
/// The database's failure cannot be recorded in that database. Bound and expose
/// safe fallback facts; never store raw errors or recursively call the ledger.
final class DiagnosticFallback: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [DiagnosticFallbackEntry] = []
    private let continuation: AsyncStream<Void>.Continuation
    let events: AsyncStream<Void>
    init() {
        let stream = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = stream.stream; continuation = stream.continuation
    }
    func record(_ failure: SafeFailure) {
        lock.lock()
        entries.append(DiagnosticFallbackEntry(id: UUID(), timestamp: Date(), failure: failure))
        if entries.count > 50 { entries.removeFirst(entries.count - 50) }
        lock.unlock()
        os_log(.fault, "Cloudified safe fallback: %{public}@", failure.description)
        continuation.yield(())
    }
    func snapshot() -> [DiagnosticFallbackEntry] { lock.lock(); defer { lock.unlock() }; return entries }
    deinit { continuation.finish() }
}
