import Foundation
import CloudifiedCore

/// Only the TDLib request boundary is synthetic; the runner extracts the actual
/// current production census method and compiles the actual reference parser.
actor CensusBoundary {
    var cursors: [Int64] = []
    var interruptOnce: Bool
    var requiresReconciliation = false
    init(interrupt: Bool) { interruptOnce = interrupt }
    func request(_ request: sending [String: Any]) throws -> TDLibResponse {
        precondition(request["limit"] as? Int == 100)
        let cursor = request["from_message_id"] as! Int64
        cursors.append(cursor)
        if cursor == 50 && interruptOnce {
            interruptOnce = false
            throw SafeFailure(.connectivity, domain: .tdlib, cause: .offline)
        }
        let tag = String(repeating: cursor == 0 ? "a" : "b", count: 64)
        let message: TDLibValue = .object([
            "@type": .string("message"), "id": .integer(cursor == 0 ? 100 : 50),
            "chat_id": .integer(-100), "is_channel_post": .boolean(true),
            "content": .object(["@type": .string("messageDocument"),
                "caption": .object(["text": .string(ContentIdentity.version + ":" + tag)]),
                "document": .object(["file_name": .string("boundary.heic"), "document": .object([
                    "id": .integer(7), "size": .integer(3), "remote": .object([
                        "is_uploading_active": .boolean(false), "is_uploading_completed": .boolean(true),
                        "unique_id": .string("boundary")])])])])])
        // A short first page still has a nonzero authoritative cursor.
        return TDLibResponse(fields: ["@type": .string("foundChatMessages"),
            "messages": .array([message]), "next_from_message_id": .integer(cursor == 0 ? 50 : 0)])
    }
}

func censusChecks(root: URL) async throws {
    for scenario in 0...2 {
        let ledger = try Ledger(databaseURL: root.appendingPathComponent(UUID().uuidString), version: "offline", revision: "unknown")
        let destination = try await ledger.selectDestination(Destination(provider: .telegram, verifiedFingerprint: String(repeating: "1", count: 64)))
        let boundary = CensusBoundary(interrupt: true), census = CensusHarness(ledger, boundary)
        do { try await census.scanIndex(destination: destination, chatID: -100); preconditionFailure("missed injected interruption") }
        catch { check(await !census.complete(), "partial census claimed absence") }
        if scenario == 1 { await census.invalidate() }
        if scenario == 2 {
            _ = try await ledger.beginRemoteIndex(destinationID: destination.id)
            do { try await census.scanIndex(destination: destination, chatID: -100); preconditionFailure("stale epoch resumed") }
            catch { check(await !census.complete(), "stale epoch claimed absence") }
        }
        try await census.scanIndex(destination: destination, chatID: -100)
        check(await census.complete(), "complete census not accepted")
        let cursors = await boundary.cursors
        check(cursors == (scenario != 0 ? [0, 50, 0, 50] : [0, 50, 50]), "unsafe cursor reuse or unnecessary restart")
    }
    print("PASS actual Telegram census: 100-page contract, short-page continuation, interrupted scan stays incomplete, valid cursor reuse, invalidated history restarts")
}
