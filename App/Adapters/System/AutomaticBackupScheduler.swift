import Foundation
import CloudifiedCore
#if os(iOS)
import BackgroundTasks
#endif

/// One discretionary request and one OS-owned execution grant. Registration happens
/// during launch, including launches without a visible window. No timer keepalive.
@MainActor
final class AutomaticBackupScheduler {
    static let shared = AutomaticBackupScheduler()
    var onLaunch: (@MainActor () -> Void)?
    var onExpiration: (@MainActor () -> Void)?
    var onChange: (@MainActor () -> Void)?
    var onTrace: (@MainActor (DiagnosticStatus, SafeFailure?, DiagnosticBackgroundEvent, UUID) -> Void)?
    private var buffered: [(DiagnosticStatus, SafeFailure?, DiagnosticBackgroundEvent, UUID)] = []
    private(set) var registered = false
    private(set) var scheduled = false
    private var registrationAttempted = false
    private var expiring = false
    private var grantID: UUID?
    #if os(iOS)
    private var identifier: String?
    private var task: BGProcessingTask?
    #endif

    var allowsExecution: Bool { grantID != nil && !expiring }
    var ownsTask: Bool { grantID != nil }
    var summary: String {
        if AppRuntime.isHosted { return "LiveContainer backup runs while Cloudified is open" }
        if allowsExecution { return "Automatic backup has system background time" }
        if !registered { return "Automatic background scheduling unavailable; keep Cloudified open" }
        return scheduled ? "Automatic background backup scheduled; iOS decides when" : "Automatic background backup waits for iOS scheduling"
    }
    private func emit(_ status: DiagnosticStatus, _ failure: SafeFailure?, _ event: DiagnosticBackgroundEvent, id: UUID) {
        if let onTrace { onTrace(status, failure, event, id) }
        else { buffered = Array((buffered + [(status, failure, event, id)]).suffix(8)) }
    }
    func deliverPending() {
        let pending = buffered; buffered.removeAll()
        for entry in pending { onTrace?(entry.0, entry.1, entry.2, entry.3) }
        if allowsExecution { onLaunch?() }
    }
    func register() {
        guard !registrationAttempted else { return }
        registrationAttempted = true
        BackgroundRunJournal.closeInterrupted()
        guard !AppRuntime.isHosted else { return }
        #if os(iOS)
        let permitted = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String] ?? []
        let own = (Bundle.main.bundleIdentifier ?? "") + ".automatic-backup"
        // Narrow built-plist fallback supports SideStore's renamed signed bundle.
        identifier = permitted.contains(own) ? own : permitted.first { $0.hasSuffix(".automatic-backup") && !$0.contains("*") }
        guard let identifier else {
            emit(.failed, SafeFailure(.connectivity, domain: .core, cause: .backgroundRestricted), .registrationRejected, id: UUID())
            return
        }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] incoming in
            MainActor.assumeIsolated {
                guard let self, self.task == nil, let processing = incoming as? BGProcessingTask else {
                    incoming.setTaskCompleted(success: false); return
                }
                let id = UUID()
                self.task = processing; self.grantID = id; self.expiring = false; self.scheduled = false
                BackgroundRunJournal.began(.automatic, id: id)
                processing.expirationHandler = { [weak self, weak processing] in
                    Task { @MainActor [weak self, weak processing] in
                        guard let self, let processing, self.task === processing else { return }
                        self.expiring = true
                        BackgroundRunJournal.ended(id: id, .expired)
                        self.emit(.failed, SafeFailure(.connectivity, domain: .core, cause: .backgroundExpired), .systemExpired, id: id)
                        self.onChange?()
                        if let onExpiration = self.onExpiration { onExpiration() }
                        else { self.finish(success: false) }
                    }
                }
                self.emit(.succeeded, nil, .granted, id: id)
                self.onChange?(); self.onLaunch?()
            }
        }
        if !registered {
            emit(.failed, SafeFailure(.connectivity, domain: .core, cause: .backgroundRestricted), .registrationRejected, id: UUID())
        }
        #endif
    }
    func schedule() {
        #if os(iOS)
        guard registered, !scheduled, let identifier else { return }
        let id = UUID()
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
            scheduled = true; emit(.changed, nil, .queued, id: id); onChange?()
        } catch {
            emit(.failed, SafeFailure(.connectivity, domain: .core, code: (error as NSError).code, cause: .backgroundRestricted), .submissionRejected, id: id)
        }
        #endif
    }
    func cancelPending() {
        #if os(iOS)
        if let identifier { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier) }
        if scheduled { emit(.changed, nil, .cancelledBeforeGrant, id: UUID()) }
        #endif
        scheduled = false; onChange?()
    }
    /// Called after workers settle, or to relinquish an unused grant. OS file
    /// transfers and native pending-send inputs are not cancelled here.
    func finish(success: Bool) {
        #if os(iOS)
        guard let task, let id = grantID else { return }
        self.task = nil; grantID = nil; expiring = false
        BackgroundRunJournal.ended(id: id, success ? .finished : .incomplete)
        task.expirationHandler = nil; task.setTaskCompleted(success: success)
        emit(success ? .succeeded : .changed, nil, success ? .completed : .endedIncomplete, id: id)
        onChange?()
        #endif
    }
}
