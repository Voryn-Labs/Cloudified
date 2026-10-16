import Foundation

/// Protocol fixtures never enter the application target or contact Telegram.
func nativeProtocolChecks() async throws {
    let file: [String: Any] = [
        "@type": "file", "id": 7, "size": 2048, "expected_size": 2048,
        "local": ["@type": "localFile", "path": "", "can_be_downloaded": true,
                  "can_be_deleted": true, "is_downloading_active": false,
                  "is_downloading_completed": false, "download_offset": 0,
                  "downloaded_prefix_size": 0, "downloaded_size": 0],
        "remote": ["@type": "remoteFile", "id": "fixture", "unique_id": "fixture",
                   "is_uploading_active": false, "is_uploading_completed": true,
                   "uploaded_size": 2048]
    ]
    let messages: [[String: Any]] = (1...100).map { index in
        ["@type": "message", "id": index * 1_048_576, "chat_id": -100,
         "sender_id": ["@type": "messageSenderChat", "chat_id": -100],
         "is_outgoing": true, "is_pinned": false, "date": 1_700_000_000,
         "edit_date": 0, "is_channel_post": true, "message_thread_id": 0,
         "content": ["@type": "messageDocument", "document": [
             "@type": "document", "file_name": "fixture.heic", "mime_type": "image/heic",
             "document": file, "thumbnail": ["@type": "thumbnail",
                 "format": ["@type": "thumbnailFormatJpeg"], "width": 100, "height": 100, "file": file]],
             "caption": ["@type": "formattedText", "text": "fixture", "entities": []]]]
    }
    let page: [String: Any] = ["@type": "messages", "@client_id": 1,
                               "total_count": 100, "messages": messages]
    func nodes(_ value: Any) -> Int {
        if let object = value as? [String: Any] { return object.values.reduce(0) { $0 + nodes($1) } }
        if let array = value as? [Any] { return 1 + array.reduce(0) { $0 + nodes($1) } }
        return 1
    }
    check(nodes(page) > 4096, "history fixture does not reproduce the old node budget")
    let data = try JSONSerialization.data(withJSONObject: page)
    check(data.count < 256 * 1024, "fixture should isolate the old node cap from the byte cap")
    let decoded = try TDLibJSON.parse(String(decoding: data, as: UTF8.self))
    check(decoded.array(forKey: "messages")?.count == 100, "full history page rejected")
    func rejects(_ value: String, _ limit: TDLibResponseLimit) {
        do { _ = try TDLibJSON.parse(value); preconditionFailure("decoder bound bypassed") }
        catch { check((error as? TDLibError) == .responseLimitExceeded(limit), "expected \(limit), got \(error)") }
    }
    rejects("{\"value\":\"" + String(repeating: "x", count: TDLibJSON.maxJSONBytes) + "\"}", .bytes)
    rejects("{\"value\":[" + Array(repeating: "0", count: TDLibJSON.maxValueNodes).joined(separator: ",") + "]}", .nodes)
    rejects("{\"value\":" + String(repeating: "[", count: 34) + "0" + String(repeating: "]", count: 34) + "}", .depth)
    do { _ = try TDLibJSON.parse("not-json"); preconditionFailure("malformed JSON accepted") }
    catch { check((error as? TDLibError) == .malformedResponse, "malformed JSON mislabeled") }
    let closed = ProtocolRecoveryHarness(.acknowledged)
    try await closed.closeForProtocolRecovery()
    check(await closed.acknowledged(), "protocol recovery skipped native close")
    for outcome in [ProtocolRecoveryHarness.CloseOutcome.unresolved, .differentError] {
        let pending = ProtocolRecoveryHarness(outcome)
        do { try await pending.closeForProtocolRecovery(); preconditionFailure("unsafe protocol fault clear") }
        catch { }
    }
    print("PASS actual protocol restart: exact fault swallowed only after acknowledged closure; unresolved closure and unrelated errors stay fenced")
    print("PASS actual TDLib decoder: 100-document history exceeds old 4,096-node budget; new bounded page succeeds; byte/node/depth limits and malformed responses stay distinct")
}
