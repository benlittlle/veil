import Foundation
import Testing
@testable import VeilCore

/// Regressions for issues found in the independent security review.
@Suite("Review regressions")
struct ReviewRegressionTests {
    /// A sender slow enough for a second click to land mid-send.
    final class SlowSender: MessageSender {
        let lock = NSLock(); var count = 0
        func send(_ text: String, toChatGUID guid: String) throws {
            Thread.sleep(forTimeInterval: 0.2); lock.lock(); count += 1; lock.unlock()
        }
    }

    @Test func doubleApprovalSendsOnce() throws {
        let h = try Harness()
        let slow = SlowSender()
        let gate = Gate(permissions: h.gate.permissions, log: AccessLog(url: nil), contacts: StaticContacts(DemoData.contacts),
                        sender: slow, openStore: { try h.gate.messagesStore() })
        let id = try #require(Harness.Out(result: gate.call(tool: "request_send", arguments: ["chat_id": .string(ID.mom), "text": "hi"], client: "t")).json["request_id"]?.string)
        DispatchQueue.concurrentPerform(iterations: 4) { _ in gate.approve(id) }
        #expect(slow.count == 1)
        #expect(gate.sends.first?.status == .sent)
    }

    @Test func requestSendIsRateLimited() throws {
        let h = try Harness()
        for i in 0..<3 { #expect(!h.call("request_send", ["chat_id": .string(ID.mom), "text": .string("msg \(i)")]).isError) }
        #expect(h.call("request_send", ["chat_id": .string(ID.mom), "text": "one more"]).isError)
    }

    @Test func sendTextCannotHideContent() throws {
        let h = try Harness()
        for t in ["Sounds good" + String(repeating: "\n", count: 200) + "hidden", "abc\u{202E}gnp.exe", "zero\u{200B}width",
                  String(repeating: "x", count: 2001), "a\n\n\nb"] {
            #expect(h.call("request_send", ["chat_id": .string(ID.mom), "text": .string(t)]).isError, "accepted: \(t.prefix(20))")
        }
        #expect(!h.call("request_send", ["chat_id": .string(ID.mom), "text": "On my way 👩‍👩‍👧 see you\nsoon"]).isError)
    }

    @Test func clientCannotImpersonateUser() {
        #expect(MCPServer.clientLabel("You") == "Unknown assistant")
        #expect(MCPServer.clientLabel(" me ") == "Unknown assistant")
        #expect(MCPServer.clientLabel("My\u{202E}Bot") == "MyBot")
        #expect(MCPServer.clientLabel("Assistant") == "Assistant")
    }

    @Test func lockedChatOrderDoesNotRevealActivity() throws {
        let h = try Harness()
        let order1 = h.call("list_chats").json["chats"]?.array?.compactMap { $0["chat_id"]?.string } ?? []
        // New message arrives in the locked therapist chat.
        let db = try SQLiteDB(path: h.dir.appendingPathComponent("chat.db").path, readOnly: false)
        let now = appleTimestamp(Date())
        try db.query("INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me) VALUES (999, 'NEW', 'SECRET new', 3, ?, 0)", [.int(now)])
        try db.query("INSERT INTO chat_message_join VALUES (4, 999, ?)", [.int(now)])
        let order2 = h.call("list_chats").json["chats"]?.array?.compactMap { $0["chat_id"]?.string } ?? []
        #expect(order1 == order2)
    }

    @Test func pagingDoesNotSkipSyncedMessages() throws {
        let h = try Harness()
        // An old message (synced later) with a high ROWID.
        let db = try SQLiteDB(path: h.dir.appendingPathComponent("chat.db").path, readOnly: false)
        let old = appleTimestamp(Date().addingTimeInterval(-500 * 3600))
        try db.query("INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me) VALUES (5000, 'SYNC', 'from iCloud', 1, ?, 0)", [.int(old)])
        try db.query("INSERT INTO chat_message_join VALUES (1, 5000, ?)", [.int(old)])
        var texts: [String] = []; var cursor: JSON? = nil
        repeat {
            var args: [String: JSON] = ["chat_id": .string(ID.mom), "limit": 2]
            if let cursor { args["before_message_id"] = cursor }
            let page = h.call("read_chat", .object(args)).json
            texts += page["messages"]?.array?.compactMap { $0["text"]?.string } ?? []
            cursor = page["older_messages_cursor"]
        } while cursor != nil
        #expect(texts.contains("from iCloud"))
        // A cursor pointing at another chat's message returns nothing rather than probing it.
        let probe = h.call("read_chat", ["chat_id": .string(ID.mom), "before_message_id": 1]).json["messages"]?.array
        #expect(probe?.isEmpty == true)
    }

    @Test func searchFindsNonASCIIAndEmptyTextRows() throws {
        let h = try Harness()
        let db = try SQLiteDB(path: h.dir.appendingPathComponent("chat.db").path, readOnly: false)
        let t = appleTimestamp(Date().addingTimeInterval(-3600))
        try db.query("INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me) VALUES (6000, 'U', 'ÉTÉ à Paris', 1, ?, 0)", [.int(t)])
        try db.query("INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me) VALUES (6001, 'E', '', ?, 1, ?, 0)",
                     [.blob(DemoData.archived("empty text column but body")), .int(t)])
        try db.query("INSERT INTO chat_message_join VALUES (1, 6000, ?), (1, 6001, ?)", [.int(t), .int(t)])
        #expect(h.call("search_messages", ["query": "été"]).json["results"]?.array?.count == 1)
        #expect(h.call("search_messages", ["query": "column but"]).json["results"]?.array?.count == 1)
    }

    @Test func originMustMatchExactly() throws {
        let h = try Harness()
        let http = LocalHTTPServer(port: 0, token: "tok", server: h.server)
        var r = HTTPRequest(method: "POST", path: "/mcp")
        r.headers = ["host": "127.0.0.1:0", "authorization": "Bearer tok", "origin": "http://localhost.evil.com"]
        r.body = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        #expect(http.respond(r).0 == "403 Forbidden")
    }

    @Test func resetClearsEverythingPending() throws {
        let h = try Harness()
        h.call("draft_reply", ["chat_id": .string(ID.mom), "text": "x"])
        let id = try #require(h.call("request_send", ["chat_id": .string(ID.mom), "text": "y"]).json["request_id"]?.string)
        try h.gate.resetAll()
        #expect(h.gate.drafts.isEmpty)
        h.gate.approve(id)
        #expect(h.sender.sent.isEmpty)
    }
}
