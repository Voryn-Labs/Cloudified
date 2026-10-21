import Foundation
import CloudifiedCore
import UIKit
#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
#endif

/// The last OS background grant. Kept in UserDefaults, which is deleted with the
/// app. An open record at launch means the process ended before the grant did.
struct BackgroundRun: Codable, Equatable {
    enum Kind: String, Codable { case continued, automatic }
    enum Outcome: String, Codable { case finished, incomplete, expired, interrupted }
    let id: UUID
    let kind: Kind
    let started: Date
    var ended: Date?
    var outcome: Outcome?
    var savedAtStart: Int?
    var savedAtEnd: Int?
    var acknowledged = false

    var summary: String {
        var parts = [started.formatted(date: .abbreviated, time: .shortened)]
        if let ended {
            parts.append(Duration.seconds(max(0, ended.timeIntervalSince(started)))
                .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2)))
        }
        if let start = savedAtStart, let end = savedAtEnd { parts.append("\(max(0, end - start)) saved") }
        switch outcome {
        case .finished: parts.append("Finished")
        case .incomplete: parts.append("Stopped with work left")
        case .expired: parts.append("Ended by iOS or from the Live Activity")
        case .interrupted: parts.append("Cloudified was closed before it finished")
        case nil: parts.append("Running")
        }
        return parts.joined(separator: " · ")
    }
}

@MainActor
enum BackgroundRunJournal {
    private static let key = "CloudifiedLastBackgroundRun"
    static var last: BackgroundRun? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(BackgroundRun.self, from: data)
    }
    private static func store(_ run: BackgroundRun) {
        if let data = try? JSONEncoder().encode(run) { UserDefaults.standard.set(data, forKey: key) }
    }
    static func began(_ kind: BackgroundRun.Kind, id: UUID) {
        store(BackgroundRun(id: id, kind: kind, started: Date()))
    }
    /// Must run before setTaskCompleted; iOS may suspend the process right after.
    static func ended(id: UUID, _ outcome: BackgroundRun.Outcome) {
        guard var run = last, run.id == id, run.outcome == nil else { return }
        run.ended = Date(); run.outcome = outcome; store(run)
    }
    static func recordSaved(id: UUID, count: Int, atEnd: Bool) {
        guard var run = last, run.id == id else { return }
        if atEnd { run.savedAtEnd = count } else if run.savedAtStart == nil { run.savedAtStart = count }
        store(run)
    }
    /// Once per process, before any launch handler can begin a new grant.
    static func closeInterrupted() {
        guard var run = last, run.outcome == nil else { return }
        run.outcome = .interrupted; store(run)
    }
    static func acknowledge() {
        guard var run = last, !run.acknowledged else { return }
        run.acknowledged = true; store(run)
    }
}

/// A finite grant measures new work, excluding historical confirmations. Later
/// library additions belong to the next run rather than moving this denominator.
struct ContinuedWorkProgress {
    private var baseline: (confirmed: Int, remaining: Int)?
    mutating func reset() { baseline = nil }
    mutating func sample(confirmed: Int, total: Int, fractions: [Double]) -> (done: Int64, total: Int64)? {
        let units: Int64 = 1_000_000
        guard total >= 0, total <= Int(Int64.max / units) else { return nil }
        if baseline == nil {
            let saved = max(0, min(confirmed, total))
            baseline = (saved, total - saved)
        }
        let start = baseline!
        let goal = max(1, Int64(start.remaining) * units)
        let completed = max(0, min(start.remaining, max(0, confirmed) - start.confirmed))
        var done = start.remaining == 0 ? goal : Int64(completed) * units
        for fraction in fractions.prefix(64) where fraction.isFinite && fraction > 0 {
            let partial = Int64(min(0.999999, fraction) * Double(units))
            let sum = done.addingReportingOverflow(partial)
            done = sum.overflow ? goal : min(goal, sum.partialValue)
        }
        if completed < start.remaining { done = min(done, goal - 1) }
        return (done, goal)
    }
}

/// User-started continued processing reports measured work; no timer heartbeat.
@MainActor
final class BackupContinuation {
    enum State: String, Equatable { case unavailable, idle, requested, running, expired }
    private(set) var state: State = .unavailable
    var onChange: (@MainActor () -> Void)?
    var onExpiration: (@MainActor () -> Void)?
    private(set) var submissionErrorCode: Int?
    private(set) var diagnosticID = UUID()
    var onTrace: (@MainActor (DiagnosticStatus, SafeFailure?, DiagnosticBackgroundEvent) -> Void)?
    private var grace: UIBackgroundTaskIdentifier = .invalid
    private var lastSubtitle: String?
    private var runProgress = ContinuedWorkProgress()
    private var progressDestinations: Set<UUID>?
    private(set) var requestedAt: TimeInterval?
    #if os(iOS) && !targetEnvironment(macCatalyst)
    private var identifier: String?
    private var registeredIdentifiers: [String: String] = [:]
    private var task: BGContinuedProcessingTask?
    private let prefixes: [String]
    #endif

    /// Prefer the signed bundle when permitted; retain the narrow built-plist
    /// fallback used by pinned PhotosBackup for SideStore's bundle renaming.
    static func identifierPrefixes(bundleID: String?, permitted: [String]) -> [String] {
        let entries = Array(permitted.prefix(32)).filter { $0.hasSuffix(".backup.*") }
        var result: [String] = []
        if let bundleID, !bundleID.isEmpty {
            let own = bundleID + ".backup."
            if entries.contains(where: { own.hasPrefix(String($0.dropLast())) }) { result.append(own) }
        }
        for entry in entries {
            let prefix = String(entry.dropLast())
            if !result.contains(prefix) { result.append(prefix) }
        }
        return Array(result.prefix(4))
    }
    init() {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        prefixes = AppRuntime.isHosted ? [] : Self.identifierPrefixes(bundleID: Bundle.main.bundleIdentifier,
            permitted: Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? [])
        state = prefixes.isEmpty ? .unavailable : .idle
        #endif
    }
    /// Foreground only. Register each concrete identifier once per process;
    /// reuse its handler for subsequent backup runs.
    func request() throws {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard task == nil, state == .idle || state == .expired || (state == .unavailable && !prefixes.isEmpty) else { return }
        submissionErrorCode = nil; diagnosticID = UUID(); requestedAt = ProcessInfo.processInfo.systemUptime
        runProgress.reset(); progressDestinations = nil
        onTrace?(.started, nil, .requestStarted)
        for prefix in prefixes {
            let id: String
            if let registered = registeredIdentifiers[prefix] { id = registered }
            else {
                id = prefix + UUID().uuidString
                let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
                    MainActor.assumeIsolated {
                        guard let self, self.identifier == id, self.state == .requested,
                              let continued = task as? BGContinuedProcessingTask else {
                            self?.onTrace?(.failed, SafeFailure(.connectivity, domain: .core, cause: .backgroundRestricted), .handlerRejected)
                            task.setTaskCompleted(success: false); return
                        }
                        self.task = continued; self.state = .running
                        BackgroundRunJournal.began(.continued, id: self.diagnosticID)
                        self.endGrace(); self.onTrace?(.succeeded, nil, .granted)
                        continued.expirationHandler = { [weak self, weak continued] in
                            Task { @MainActor [weak self, weak continued] in
                                // Identifiers are reused. A delayed expiration
                                // from the old task must never cancel its successor.
                                guard let self, let continued, self.task === continued else { return }
                                BackgroundRunJournal.ended(id: self.diagnosticID, .expired)
                                self.onTrace?(.failed, SafeFailure(.connectivity, domain: .core, cause: .backgroundExpired), .systemExpired)
                                self.state = .expired; self.onChange?(); self.onExpiration?()
                            }
                        }
                        self.onChange?()
                    }
                }
                guard registered else {
                    submissionErrorCode = BGTaskScheduler.Error.Code.notPermitted.rawValue
                    onTrace?(.failed, SafeFailure(.connectivity, domain: .core, code: submissionErrorCode, cause: .backgroundRestricted), .registrationRejected)
                    continue
                }
                registeredIdentifiers[prefix] = id
            }
            identifier = id; state = .requested
            let request = BGContinuedProcessingTaskRequest(identifier: id, title: "Cloudified backup", subtitle: "Checking originals")
            request.strategy = .queue
            do { try BGTaskScheduler.shared.submit(request); onTrace?(.changed, nil, .queued); onChange?(); return }
            catch {
                identifier = nil; state = .idle
                let code = (error as NSError).code; submissionErrorCode = code
                onTrace?(.failed, SafeFailure(.connectivity, domain: .core, code: code, cause: .backgroundRestricted), .submissionRejected)
                if code != BGTaskScheduler.Error.Code.notPermitted.rawValue {
                    onChange?()
                    throw SafeFailure(.connectivity, domain: .core, code: code, cause: .backgroundRestricted)
                }
            }
        }
        state = .unavailable; onChange?()
        onTrace?(.failed, SafeFailure(.connectivity, domain: .core, code: submissionErrorCode, cause: .backgroundRestricted), .unavailable)
        throw SafeFailure(.connectivity, domain: .core, code: submissionErrorCode, cause: .backgroundRestricted)
        #endif
    }
    /// Fractions include confirmed component receipts and real bytes within each
    /// active asset. A retry may reduce its fraction; it never becomes Saved here.
    /// Before the first complete scan there is no total; scan pages are then the
    /// measured work, so a long first scan does not look stuck to iOS.
    func update(confirmed: Int, total: Int?, activeFractions: [Double], subtitle: String,
                scope: Set<UUID>, scan: (done: Int, total: Int)? = nil) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard let task, state == .running else { return }
        if progressDestinations != scope {
            progressDestinations = scope; runProgress.reset()
        }
        if let total, let sample = runProgress.sample(confirmed: confirmed, total: total, fractions: activeFractions) {
            if task.progress.totalUnitCount != sample.total { task.progress.totalUnitCount = sample.total }
            if task.progress.completedUnitCount != sample.done { task.progress.completedUnitCount = sample.done }
        } else if let scan, scan.total > 0 {
            let goal = Int64(scan.total), done = Int64(max(0, min(scan.done, scan.total)))
            if task.progress.totalUnitCount != goal { task.progress.totalUnitCount = goal }
            if task.progress.completedUnitCount != done { task.progress.completedUnitCount = done }
        } else if task.progress.totalUnitCount != -1 { task.progress.totalUnitCount = -1 }
        if lastSubtitle != subtitle { task.updateTitle("Cloudified backup", subtitle: subtitle); lastSubtitle = subtitle }
        #endif
    }
    /// Normal completion joins workers first. Expiration completes the OS task
    /// promptly while durable input holds protect any still-joining readers.
    func finish(success: Bool) {
        endGrace(); lastSubtitle = nil; runProgress.reset(); progressDestinations = nil
        #if os(iOS) && !targetEnvironment(macCatalyst)
        guard state != .idle && state != .unavailable else { return }
        if let task {
            BackgroundRunJournal.ended(id: diagnosticID, success ? .finished : .incomplete)
            onTrace?(success ? .succeeded : .changed, nil, success ? .completed : .endedIncomplete)
            task.expirationHandler = nil; task.setTaskCompleted(success: success); self.task = nil }
        else if state == .requested, let identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            onTrace?(.changed, nil, .cancelledBeforeGrant)
        }
        identifier = nil; state = .idle; onChange?()
        #endif
    }
    /// A short OS-granted handoff window avoids cancelling a 90%-sent file while
    /// a continued request's launch handler is still queued. It is not a timer
    /// keepalive and its expiration restores normal policy gating.
    func beginGrace() {
        guard grace == .invalid, state != .running else { return }
        grace = UIApplication.shared.beginBackgroundTask(withName: "Cloudified transfer handoff") { [weak self] in
            MainActor.assumeIsolated {
                self?.endGrace(); self?.onChange?()
                self?.onTrace?(.failed, SafeFailure(.connectivity, domain: .core, cause: .backgroundExpired), .graceExpired)
            }
        }
    }
    func endGrace() {
        guard grace != .invalid else { return }
        UIApplication.shared.endBackgroundTask(grace); grace = .invalid
    }
    var allowsBackgroundExecution: Bool { state == .running || grace != .invalid }
    /// BGTaskScheduler rejected the request because Background App Refresh is off.
    var refreshDisabled: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return submissionErrorCode == BGTaskScheduler.Error.Code.unavailable.rawValue
        #else
        return false
        #endif
    }
    var summary: String {
        if let submissionErrorCode, state == .unavailable || state == .idle {
            return Self.explainSubmission(submissionErrorCode)
        }
        switch state {
        case .unavailable: return "This build cannot ask iOS for background time. Keep Cloudified open."
        case .idle: return "A Google file already handed to iOS keeps uploading after you leave."
        case .requested: return "Waiting for iOS to allow background time."
        case .running: return "Keeps going after you leave. Closing Cloudified from the app switcher stops it."
        case .expired: return "Background time ended. Open Cloudified to continue."
        }
    }
    static func explainSubmission(_ code: Int) -> String {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        switch BGTaskScheduler.Error.Code(rawValue: code) {
        case .unavailable:
            return "Background App Refresh is off for Cloudified. Turn it on in Settings, or keep Cloudified open."
        case .notPermitted:
            return "iOS rejected the background task name. The signed app ID may not match this build. Keep Cloudified open."
        case .tooManyPendingTaskRequests:
            return "iOS already holds too many background requests from Cloudified. Keep Cloudified open."
        default: break
        }
        #endif
        return "iOS refused background time (code \(code)). Keep Cloudified open."
    }
}
