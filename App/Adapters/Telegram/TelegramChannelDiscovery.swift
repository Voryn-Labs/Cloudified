import Foundation
import CloudifiedCore

public struct TelegramChannel: Identifiable, Sendable, Equatable {
    public let id: Int64
    public let title: String
}

public struct TelegramChannelSelection: Sendable, Equatable {
    public let channel: TelegramChannel
    public let accountID: Int64
    public let accountName: String
}

public struct TelegramChannelPage: Sendable {
    public let channels: [TelegramChannel]
    public let checked: Int
    public let candidateCount: Int
    public let hasMore: Bool
}

/// A bounded, informational candidate window, never an exhaustive account index.
/// No update subscriber or child Task: cancellation belongs to the caller.
public actor TelegramChannelDiscovery {
    private let client: TDLibClient
    private let query: String
    private var candidates: [Int64]?
    private var cursor = 0
    private var channels: [TelegramChannel] = []
    private var accountID: Int64?
    private var activeOperation: UUID?
    private var operationDeadline: TimeInterval?

    public init(client: TDLibClient, query: String = "") {
        self.client = client
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func discoverMore(limit: Int = 10) async throws -> TelegramChannelPage {
        let operation = try beginOperation()
        defer { endOperation(operation) }
        _ = try await authenticatedAccount()
        if candidates == nil {
            var ids: [Int64] = []
            if query.isEmpty {
                for list in ["chatListMain", "chatListArchive"] {
                    do {
                        _ = try await read(["@type": "loadChats", "chat_list": ["@type": list], "limit": 50])
                    } catch {
                        try Task.checkCancellation()
                        guard ProviderSupport.safe(error, domain: .tdlib).code == 404 else { throw error }
                    }
                    let response = try await read(["@type": "getChats", "chat_list": ["@type": list], "limit": 50])
                    ids.append(contentsOf: try chatIDs(response, maximum: 50))
                }
            } else {
                let response = try await read(["@type": "searchChatsOnServer", "query": query,
                    "type_filter": ["@type": "searchChatTypeFilterChannel"], "limit": 50])
                ids = try chatIDs(response, maximum: 50)
            }
            try Task.checkCancellation()
            var seen = Set<Int64>()
            candidates = ids.filter { seen.insert($0).inserted }
        }
        let ids = candidates ?? []
        let end = min(ids.count, cursor + min(10, max(1, limit)))
        while cursor < end {
            let id = ids[cursor]
            let channel = try await inspect(id)
            try Task.checkCancellation()
            // Commit each verified result atomically; a later failure does not lose it.
            if let channel { channels.append(channel) }
            cursor += 1
        }
        return snapshot()
    }

    public func snapshot() -> TelegramChannelPage {
        TelegramChannelPage(channels: channels, checked: cursor,
            candidateCount: candidates?.count ?? 0,
            hasMore: candidates == nil || cursor < (candidates?.count ?? 0))
    }

    /// Read-only identity review. Mapping still performs authoritative verification.
    public func selection(chatID: Int64) async throws -> TelegramChannelSelection {
        let operation = try beginOperation()
        defer { endOperation(operation) }
        let account = try await authenticatedAccount()
        guard let channel = try await inspect(chatID) else {
            throw SafeFailure(.accessDenied, domain: .tdlib, cause: .privateChannelRequired)
        }
        try Task.checkCancellation()
        return TelegramChannelSelection(channel: channel, accountID: account.id, accountName: account.name)
    }

    private func beginOperation() throws -> UUID {
        try Task.checkCancellation()
        guard activeOperation == nil else { throw CoreError.invalidTransition }
        let id = UUID(); activeOperation = id
        operationDeadline = ProcessInfo.processInfo.systemUptime + 30
        return id
    }
    private func endOperation(_ id: UUID) {
        if activeOperation == id { activeOperation = nil; operationDeadline = nil }
    }
    private func authenticatedAccount() async throws -> (id: Int64, name: String) {
        let me = try await read(["@type": "getMe"])
        guard let id = me.int64(forKey: "id"), id > 0,
              me.object(forKey: "type")?.type == "userTypeRegular" else { throw malformed }
        if let accountID, accountID != id { throw CancellationError() }
        accountID = id
        let name = [me.string(forKey: "first_name"), me.string(forKey: "last_name")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        return (id, name.isEmpty ? String(id) : name)
    }
    private func read(_ request: sending [String: Any]) async throws -> TDLibResponse {
        try Task.checkCancellation()
        guard await client.authorizationState == .ready else {
            throw SafeFailure(.authentication, domain: .tdlib, cause: .loginRequired)
        }
        guard !(await client.requiresReconciliation) else {
            throw SafeFailure(.invariant, domain: .tdlib, cause: .interrupted)
        }
        // Right after sign-in TDLib reports Connecting/Updating for a few seconds.
        var waits = 0
        while !(await client.connectionReady) {
            guard waits < 20 else { throw SafeFailure(.connectivity, domain: .tdlib, cause: .offline) }
            try await Task.sleep(for: .milliseconds(250)); waits += 1
        }
        let remaining = (operationDeadline ?? 0) - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { throw SafeFailure(.timeout, domain: .tdlib, cause: .deadlineExceeded) }
        let result = try await client.request(request, timeout: min(10, remaining))
        try Task.checkCancellation()
        guard await client.authorizationState == .ready else { throw CancellationError() }
        return result
    }
    private var malformed: SafeFailure {
        SafeFailure(.transfer, domain: .tdlib, cause: .formatRejected)
    }
    private func chatIDs(_ response: TDLibResponse, maximum: Int) throws -> [Int64] {
        guard response.type == "chats", let values = response.array(forKey: "chat_ids"),
              values.count <= maximum else { throw malformed }
        return try values.map {
            guard let id = TDLibJSON.parseID($0), id != 0 else { throw malformed }
            return id
        }
    }
    private func inspect(_ id: Int64) async throws -> TelegramChannel? {
        let chat = try await read(["@type": "getChat", "chat_id": id])
        guard chat.type == "chat", chat.int64(forKey: "id") == id,
              let retention = chat["message_auto_delete_time"]?.int32Value,
              let type = chat.object(forKey: "type"), let kind = type.type else { throw malformed }
        guard kind == "chatTypeSupergroup" else { return nil }
        guard let isChannel = type["is_channel"]?.boolValue else { throw malformed }
        guard isChannel, retention == 0 else { return nil }
        guard let groupID = type.int64(forKey: "supergroup_id") else { throw malformed }
        let group = try await read(["@type": "getSupergroup", "supergroup_id": groupID])
        guard group.type == "supergroup", group.int64(forKey: "id") == groupID,
              let groupIsChannel = group["is_channel"]?.boolValue,
              let status = group.object(forKey: "status"), let statusType = status.type else { throw malformed }
        guard groupIsChannel, statusType == "chatMemberStatusCreator" else { return nil }
        guard let isMember = status["is_member"]?.boolValue else { throw malformed }
        if let usernames = group.object(forKey: "usernames") {
            guard let active = usernames.array(forKey: "active_usernames") else { throw malformed }
            if !active.isEmpty { return nil }
        } else if let value = group["usernames"], value != .null { throw malformed }
        guard isMember else { return nil }
        guard let title = chat.string(forKey: "title"), !title.isEmpty else { throw malformed }
        return TelegramChannel(id: id, title: title)
    }
}
