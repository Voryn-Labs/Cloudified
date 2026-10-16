import Foundation
import CloudifiedCore

struct TelegramDocumentReference: Codable, Equatable, Sendable {
    let version: Int
    let chatID: Int64
    let messageID: Int64
    let fileID: Int32
    let remoteUniqueID: String
    let byteCount: Int64
    let tag: String
    let filename: String
    static func captionTag(_ message: TDLibResponse) throws -> String? {
        guard let text = message.object(forKey: "content")?.object(forKey: "caption")?["text"]?.stringValue else { return nil }
        guard text.hasPrefix("cloudified-") else { return nil }
        let prefix = ContentIdentity.version + ":"
        guard text.hasPrefix(prefix) else { throw SafeFailure(.reconciliation, domain: .tdlib, cause: .formatRejected) }
        let tag = String(text.dropFirst(prefix.count))
        _ = try ProviderSupport.hex(tag, count: 32) // Exact canonical marker, no suffix/truncation.
        return tag
    }
    static func parse(_ message: TDLibResponse, chatID: Int64, expectedTag: String? = nil) throws -> TelegramDocumentReference? {
        guard let tag = try captionTag(message) else { return nil }
        // Local search/history can contain our pending/failed sends. They are not
        // remote receipts, but must not abort the entire archive index.
        for key in ["sending_state", "scheduling_state"] {
            if let value = message.fields[key], value != .null {
                guard value.objectValue != nil else { throw SafeFailure(.reconciliation, domain: .tdlib, cause: .formatRejected) }
                return nil
            }
        }
        guard message.type == "message", message["chat_id"]?.int64Value == chatID,
              let id = message["id"]?.int64Value, id > 0,
              message.object(forKey: "sending_state") == nil, message.object(forKey: "scheduling_state") == nil,
              message["is_channel_post"]?.boolValue == true,
              let content = message.object(forKey: "content"), content.type == "messageDocument",
              let document = content.object(forKey: "document"), let filename = document["file_name"]?.stringValue,
              filename.utf8.count <= 255,
              let file = document.object(forKey: "document"), let fileID = file["id"]?.int32Value, fileID > 0,
              let size = file["size"]?.int64Value, size > 0,
              let remote = file.object(forKey: "remote"), remote["is_uploading_active"]?.boolValue == false,
              remote["is_uploading_completed"]?.boolValue == true,
              let unique = remote["unique_id"]?.stringValue, !unique.isEmpty, unique.utf8.count <= 1024,
              expectedTag.map({ $0 == tag }) ?? true else { throw SafeFailure(.reconciliation, domain: .tdlib, cause: .outcomeUnknown) }
        return TelegramDocumentReference(version: 1, chatID: chatID, messageID: id, fileID: fileID,
                                         remoteUniqueID: unique, byteCount: size, tag: tag, filename: filename)
    }
    func validate(chatID expectedChat: Int64, tag expectedTag: String) throws {
        guard version == 1, chatID == expectedChat, tag == expectedTag, messageID > 0, fileID > 0,
              byteCount > 0, !remoteUniqueID.isEmpty, remoteUniqueID.utf8.count <= 1024,
              filename.utf8.count <= 255 else { throw CoreError.invalidContract }
        _ = try ProviderSupport.hex(tag, count: 32)
    }
}
