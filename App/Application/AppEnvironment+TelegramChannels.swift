import Foundation
import CloudifiedCore

/// Identity and command fences for ephemeral read-only presentation work.
public struct TelegramDiscoveryContext: Equatable {
    let clientID: ObjectIdentifier?
    let authStep: TelegramAuthStep
    let commandID: UUID?
    let available: Bool
}

extension AppEnvironment {
    public var telegramDiscoveryContext: TelegramDiscoveryContext {
        TelegramDiscoveryContext(clientID: tdlibClient.map(ObjectIdentifier.init),
            authStep: settingsState.telegramAuthStep, commandID: commandID,
            available: bootstrapComplete && isForeground && !shuttingDown && commandProvider == nil &&
                !controlTransition && !settingsState.isConnectingTelegram && !settingsState.isSettlingTelegram)
    }

    public func createTelegramChannelDiscovery(query: String = "") throws -> TelegramChannelDiscovery {
        let context = telegramDiscoveryContext
        guard context.available else { throw CoreError.invalidTransition }
        guard [.readyForChannel, .connected].contains(context.authStep), let client = tdlibClient else {
            throw SafeFailure(.authentication, domain: .tdlib, cause: .loginRequired)
        }
        guard allowedNetwork else {
            throw SafeFailure(.connectivity, domain: .tdlib,
                cause: network?.available == true ? .wifiRequired : .offline)
        }
        return TelegramChannelDiscovery(client: client, query: query)
    }

    /// A discovery problem must not pause the independent backup lane.
    public func recordTelegramDiscoveryFailure(_ failure: SafeFailure) async {
        do {
            try await diagnosticSink(.remoteCheck, EventContext(origin: .telegram), .wait, .warning,
                failure, nil, nil, nil)
        } catch { fallback.record(ProviderSupport.safe(error, domain: .sqlite)) }
        scheduleThrottledRefresh()
    }
}
