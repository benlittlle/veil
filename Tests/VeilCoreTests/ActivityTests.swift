import Foundation
import Testing
@testable import VeilCore

/// "Activity only": timing and direction, never content.
@Suite("Activity-only chats")
struct ActivityTests {
    /// Default access plus: Family (group, all SECRET) and the unknown number set to Activity only.
    static let access: [String: ChatAccess] = Harness.defaultAccess.merging([
        ID.family: ChatAccess(activity: true),
        ID.unknown: ChatAccess(activity: true),
    ]) { $1 }

    /// Words from the private fixture messages, names of private files, and reaction text.
    static let content = [secret, "surprise party", "cake", "Don't tell", "session notes", "4417", "Loved", "png"]

    func noContent(_ s: String, _ what: String) {
        for w in Self.content { #expect(!s.contains(w), "\(what) leaked “\(w)”") }
    }

    @Test func chatActivityReturnsTimesAndDirectionOnly() throws {
        let h = try Harness(access: Self.access)
        let out = h.call("chat_activity", ["chat_id": .string(ID.family)])
        #expect(!out.isError)
        noContent(out.raw, "chat_activity")
        let msgs = out.json["messages"]?.array ?? []
        #expect(msgs.count == 3)
        for m in msgs {
            #expect(Set(m.objectKeys).isSubset(of: ["id", "time", "direction", "from"]))
            #expect(m["direction"]?.string == "incoming")
        }
        // Groups say who sent each message (names are already visible in list_chats).
        #expect(msgs.compactMap { $0["from"]?.string } == ["Sam Patel", "Mom", "Sam Patel"])
        #expect(out.json["type"]?.string == "group")
        #expect(out.json["last_incoming_at"]?.string != nil)
        #expect(out.json["last_reply_at"] == .null)
        #expect(out.json["replied_since_last_incoming"] == .bool(false))
        #expect(out.json["note"]?.string?.contains("no message content") == true)
    }

    @Test func directChatsShowDirectionAndWhetherUserReplied() throws {
        // Therapist: incoming at -40h, the user replied at -39h.
        let h = try Harness(access: [ID.therapist: ChatAccess(activity: true), ID.alex: ChatAccess(read: true)])
        let t = h.call("chat_activity", ["chat_id": .string(ID.therapist)])
        noContent(t.raw, "therapist activity")
        let msgs = t.json["messages"]?.array ?? []
        #expect(msgs.map { $0["direction"]?.string } == ["incoming", "from_me"])
        #expect(msgs.allSatisfy { $0["from"] == nil })
        #expect(t.json["replied_since_last_incoming"] == .bool(true))
        #expect(t.json["last_reply_at"]?.string != nil)

        // Read implies activity. Alex wrote last, so the user hasn't replied.
        let a = h.call("chat_activity", ["chat_id": .string(ID.alex)])
        #expect(!a.isError)
        #expect(a.json["replied_since_last_incoming"] == .bool(false))
        #expect(a.json["note"] == nil)
    }

    @Test func tapbacksAndSystemEventsAreNotActivity() throws {
        let h = try Harness(access: [ID.mom: ChatAccess(activity: true), ID.climbing: ChatAccess(activity: true)])
        let mom = h.call("chat_activity", ["chat_id": .string(ID.mom), "limit": 200])
        noContent(mom.raw, "mom activity")
        #expect(mom.json["messages"]?.array?.count == 9)   // 10 rows minus one tapback; both chat rows (iMessage + SMS)
        #expect(h.call("chat_activity", ["chat_id": .string(ID.climbing)]).json["messages"]?.array?.count == 3)
    }

    @Test func sinceLimitAndCursor() throws {
        let h = try Harness(access: Self.access)
        let since = iso(Date().addingTimeInterval(-49.5 * 3600))
        #expect(h.call("chat_activity", ["chat_id": .string(ID.family), "since": .string(since)]).json["messages"]?.array?.count == 2)
        let first = h.call("chat_activity", ["chat_id": .string(ID.family), "limit": 2])
        #expect(first.json["messages"]?.array?.count == 2)
        let cursor = try #require(first.json["older_messages_cursor"]?.int)
        let older = h.call("chat_activity", ["chat_id": .string(ID.family), "before_message_id": JSON(cursor)])
        #expect(older.json["messages"]?.array?.count == 1)
        // A cursor from another chat returns nothing rather than probing it.
        #expect(h.call("chat_activity", ["chat_id": .string(ID.family), "before_message_id": 1]).json["messages"]?.array?.isEmpty == true)
        #expect(h.call("chat_activity", ["chat_id": .string(ID.family), "since": "yesterday"]).isError)
    }

    @Test func activityOnlyChatsRefuseEveryContentTool() throws {
        let h = try Harness(access: Self.access)
        for id in [ID.family, ID.unknown] {
            let refused: [(String, JSON)] = [
                ("read_chat", ["chat_id": .string(id), "limit": 200]),
                ("search_messages", ["query": "SECRET", "chat_id": .string(id)]),
                ("list_attachments", ["chat_id": .string(id)]),
                ("draft_reply", ["chat_id": .string(id), "text": "hi"]),
                ("request_send", ["chat_id": .string(id), "text": "hi"]),
            ]
            for (tool, args) in refused {
                let out = h.call(tool, args)
                #expect(out.isError, "\(tool) on \(id) should be refused")
                noContent(out.raw, tool)
            }
        }
        // Global search skips activity-only chats.
        for q in ["SECRET", "surprise", "cake", "4417"] {
            let out = h.call("search_messages", ["query": .string(q), "limit": 50])
            noContent(out.json["results"]?.encoded() ?? "", "search \(q)")   // the query itself is echoed back
            #expect(out.json["results"]?.array?.allSatisfy { ![ID.family, ID.unknown].contains($0["chat_id"]?.string ?? "") } == true)
        }
        // Family's photo and the shared photo stay unavailable.
        for a in [2, 3] {
            let out = h.call("get_attachment", ["attachment_id": JSON(a)])
            #expect(out.isError)
            noContent(out.raw, "get_attachment \(a)")
        }
        // Mom's read_chat must not surface the shared photo from the activity-only group.
        #expect(!h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200]).raw.contains(secret))
        #expect(!h.call("list_chats").raw.contains(secret))
    }

    @Test func waitingOnReplyIncludesActivityOnlyChatsWithoutText() throws {
        let h = try Harness(access: Self.access)
        let out = h.call("waiting_on_reply")
        noContent(out.raw, "waiting_on_reply")
        let rows = out.json["waiting"]?.array ?? []
        for id in [ID.family, ID.unknown] {
            let r = try #require(rows.first { $0["chat_id"]?.string == id }, "\(id) missing")
            #expect(r["last_message"] == nil)
            #expect(r["waiting_since"]?.string != nil)
        }
        #expect(rows.first { $0["chat_id"]?.string == ID.family }?["last_message_from"]?.string == "Sam Patel")
        // Chats with Read still include the text.
        #expect(rows.first { $0["chat_id"]?.string == ID.alex }?["last_message"]?.string == "Yes, can you book the 7pm slot?")
    }

    @Test func listChatsShowsActivityLabelAndTime() throws {
        let h = try Harness(access: Self.access)
        let chats = h.call("list_chats").json["chats"]?.array ?? []
        let fam = try #require(chats.first { $0["chat_id"]?.string == ID.family })
        #expect(fam["allowed"] == .array(["activity"]))
        #expect(fam["last_activity"]?.string != nil)
        #expect(fam["note"] == nil)
        let mom = try #require(chats.first { $0["chat_id"]?.string == ID.mom })
        #expect(mom["allowed"]?.array?.contains("activity") == false)
    }

    @Test func lockedHiddenAndPausedChatsRefuseActivity() throws {
        let h = try Harness(access: [ID.family: ChatAccess(waiting: true, draft: true, send: true, attachments: true),
                                     ID.unknown: ChatAccess(hidden: true, activity: true)])
        let locked = h.call("chat_activity", ["chat_id": .string(ID.family)])
        #expect(locked.isError)
        #expect(locked.text.contains("doesn't allow seeing activity"))
        #expect(h.call("chat_activity", ["chat_id": .string(ID.therapist)]).isError)
        let hidden = h.call("chat_activity", ["chat_id": .string(ID.unknown)])
        #expect(hidden.isError)
        #expect(hidden.text.contains("No chat with that chat_id"))
        #expect(h.call("waiting_on_reply").json["waiting"]?.array?.contains { $0["chat_id"]?.string == ID.unknown } == false)

        try h.gate.setAccess(ChatAccess(activity: true), for: ID.family)
        #expect(!h.call("chat_activity", ["chat_id": .string(ID.family)]).isError)
        try h.gate.setPaused(true)
        #expect(h.call("chat_activity", ["chat_id": .string(ID.family)]).isError)
    }

    @Test func accessIsLoggedWithoutContent() throws {
        let h = try Harness(access: Self.access)
        h.call("chat_activity", ["chat_id": .string(ID.family)])
        h.call("read_chat", ["chat_id": .string(ID.family)])
        let entries = h.gate.log.all
        let ok = try #require(entries.first { $0.tool == "chat_activity" })
        #expect(ok.outcome == .allowed)
        #expect(ok.chatID == ID.family)
        #expect(ok.summary.contains("no content"))
        #expect(entries.contains { $0.tool == "read_chat" && $0.outcome == .denied && $0.chatID == ID.family })
        let file = try String(contentsOf: h.dir.appendingPathComponent("access.jsonl"), encoding: .utf8)
        noContent(file, "access log")
    }

    @Test func signedFileStaysCompatible() throws {
        let enc = JSONEncoder.sorted
        #expect(!String(decoding: try enc.encode(ChatAccess(read: true)), as: UTF8.self).contains("activity"))
        let on = try enc.encode(ChatAccess(activity: true))
        #expect(String(decoding: on, as: UTF8.self).contains("\"activity\" : true"))
        #expect(try JSONDecoder().decode(ChatAccess.self, from: on).activity)
        // Survives a reload from disk (HMAC still verifies).
        let h = try Harness(access: [ID.family: ChatAccess(activity: true)])
        let reloaded = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        #expect(reloaded.integrity == .ok)
        #expect(reloaded.state.access(ID.family).activity)
    }
}

@Suite("Activity pings")
struct ActivityPingTests {
    @Test func activityOnlyChatsPingIncomingAndUsersReplies() async throws {
        let p = try PingHarness(access: ActivityTests.access)
        let incoming = try p.incoming(chatRow: 7)                  // Family: activity only
        p.notifier.tick()
        await p.settle { p.transport.requests.count >= 1 }
        try p.incoming(chatRow: 5, fromMe: true)                   // Unknown: activity only, the user replies
        try p.incoming(chatRow: 3, fromMe: true)                   // Alex: Read but not Activity, no reply ping
        try p.incoming(chatRow: 4)                                 // Therapist: locked
        p.notifier.tick()
        await p.settle { p.transport.requests.count >= 2 }

        #expect(p.transport.requests.count == 2)
        let fam = try #require(p.bodies.first { $0["chat_id"] as? String == ID.family })
        #expect(fam["direction"] as? String == "incoming")
        #expect((fam["message_id"] as? NSNumber)?.int64Value == incoming)
        let reply = try #require(p.bodies.first { $0["chat_id"] as? String == ID.unknown })
        #expect(reply["direction"] as? String == "from_me")
        #expect(Set(reply.keys) == ["event", "chat_id", "message_id", "received_at", "direction"])
        let raw = p.transport.requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }.joined()
        for leak in [secret, "Family surprise", "Mom", "Sam", ID.therapist, ID.alex] { #expect(!raw.contains(leak)) }
    }

    @Test func replyPingsCanBeTurnedOff() async throws {
        let p = try PingHarness(access: ActivityTests.access)
        p.notifier.configure(WebhookConfig(url: URL(string: "https://hooks.example.com/ping")!, headerName: "Authorization",
                                           key: p.key, pingReplies: false))
        try p.incoming(chatRow: 5, fromMe: true)
        try p.incoming(chatRow: 7, fromMe: true)
        p.notifier.tick()
        await p.settle()
        #expect(p.transport.requests.isEmpty)
    }

    @Test func turningActivityOffBeforeDeliveryDropsThePing() async throws {
        let p = try PingHarness(access: ActivityTests.access)
        p.transport.responses = [(503, nil), (200, nil)]
        p.transport.holding = true                     // the 503 only arrives once Activity is off
        try p.incoming(chatRow: 7)
        p.notifier.tick()
        #expect(p.transport.requests.count == 1)
        try p.h.gate.setAccess(ChatAccess(), for: ID.family)
        p.transport.release()
        await p.settle { p.notifier.log.all.contains { $0.outcome == .dropped } }
        #expect(p.transport.requests.count == 1)
        #expect(p.notifier.log.all.contains { $0.outcome == .dropped && $0.chatID == ID.family })
    }
}
