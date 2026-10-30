import Foundation
import CloudifiedCore

extension AppEnvironment {
    func saveAlbumExclusions(google: Set<String>, telegram: Set<String>) async throws {
        guard !backupRequested, backupExecutionTask == nil, !controlTransition,
              commandProvider == nil, bootstrapComplete, let ledger else {
            throw SafeFailure(.connectivity, domain: .core, cause: .operationBusy)
        }
        controlTransition = true
        defer { controlTransition = false; scheduleThrottledRefresh(); scheduleAutomaticBackup() }
        try await ledger.setAlbumExclusions([.google: google, .telegram: telegram])
        planningEpoch += 1; planningCursors.removeAll(); needsFreshScan = true
        for provider in Provider.allCases {
            do { try await AlbumExclusionPolicy.refresh(ledger, provider: provider) }
            catch { await report(error, provider: provider) }
        }
        await refreshStoredSettings()
    }
}
