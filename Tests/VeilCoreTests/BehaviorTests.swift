import Foundation
import Testing
@testable import VeilCore

@Suite("Reading")
struct ReadingTests {
    @Test func readsBothServicesAsOneConversationWithDecodedText() throws {
        let h = try Harness()
        let msgs = h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200]).json["messages"]?.array ?? []
        let texts = msgs.compactMap { $0["text"]?.string }
        #expect(texts.contains("Your package arrived here btw"))              // SMS row
        #expect(texts.contains("Dad says hi and wants the hiking photos"))    // attributedBody only
        #expect(texts.last == "Call me when you can")                         // oldest → newest
        #expect(msgs.first?["from"]?.string == "Mom")
        #expect(msgs.contains { $0["from"]?.string == "me" })
    }

    @Test func pagesThroughFullHistory() throws {
        let h = try Harness()
        var seen: [Int] = []
        var cursor: JSON? = nil
        repeat {
            var args: [String: JSON] = ["chat_id": .string(ID.mom), "limit": 3]
            if let cursor { args["before_message_id"] = cursor }
            let page = h.call("read_chat", .object(args)).json
            seen += page["messages"]?.array?.compactMap { $0["id"]?.int } ?? []
            cursor = page["older_messages_cursor"]
        } while cursor != nil
        #expect(seen.count == 9)
        #expect(Set(seen).count == 9)
    }

    @Test func searchFindsTextStoredOnlyInAttributedBody() throws {
        let h = try Harness()
        let r = h.call("search_messages", ["query": "hiking"]).json["results"]?.array ?? []
        #expect(r.count == 1 && r.first?["chat_id"]?.string == ID.mom)
    }

    @Test func decodesLongAttributedBodies() throws {
        let long = String(repeating: "héllo wörld ", count: 40)  // > 255 bytes, uses the 0x81 length form
        #expect(AttributedBody.text(from: DemoData.archived(long)) == long)
        #expect(AttributedBody.text(from: DemoData.archived("hi 👋")) == "hi 👋")
        #expect(AttributedBody.text(from: Data([0, 1, 2])) == nil)
    }
}

@Suite("Turning things off")
struct RevocationTests {
    @Test func turningOffReadStopsImmediately() throws {
        let h = try Harness()
        #expect(!h.call("read_chat", ["chat_id": .string(ID.mom)]).isError)
        try h.gate.setAccess(ChatAccess(), for: ID.mom)
        #expect(h.call("read_chat", ["chat_id": .string(ID.mom)]).isError)
        #expect(h.call("search_messages", ["query": "dinner"]).json["results"]?.array?.isEmpty == true)
        #expect(h.call("get_attachment", ["attachment_id": 1]).isError)
        #expect(!(h.call("waiting_on_reply").json["waiting"]?.array ?? []).contains { $0["chat_id"]?.string == ID.mom })
    }

    @Test func turningOffPurgesDraftsAndPendingSends() throws {
        let h = try Harness()
        h.call("draft_reply", ["chat_id": .string(ID.mom), "text": "See you Sunday"])
        let req = h.call("request_send", ["chat_id": .string(ID.mom), "text": "On my way"]).json["request_id"]?.string
        #expect(h.gate.drafts.count == 1)
        try h.gate.setAccess(ChatAccess(read: true), for: ID.mom)
        #expect(h.gate.drafts.isEmpty)
        #expect(h.gate.sends.first?.status == .cancelled("sending was turned off for this chat"))
        h.gate.approve(try #require(req))
        #expect(h.sender.sent.isEmpty)
    }

    @Test func pauseBlocksEverything() throws {
        let h = try Harness()
        try h.gate.setPaused(true)
        for tool in ["list_chats", "read_chat", "search_messages", "waiting_on_reply", "get_attachment", "draft_reply", "request_send"] {
            #expect(h.call(tool, ["chat_id": .string(ID.mom), "query": "dinner", "attachment_id": 1, "text": "hi"]).isError, "\(tool) while paused")
        }
        try h.gate.setPaused(false)
        #expect(!h.call("list_chats").isError)
    }
}

@Suite("Drafts and sending")
struct SendingTests {
    @Test func draftNeverSends() throws {
        let h = try Harness()
        let out = h.call("draft_reply", ["chat_id": .string(ID.alex), "text": "Booked 7pm!"])
        #expect(!out.isError)
        #expect(h.gate.drafts.first?.text == "Booked 7pm!")
        #expect(h.sender.sent.isEmpty)
        #expect(h.call("draft_reply", ["chat_id": .string(ID.climbing), "text": "x"]).isError)
    }

    @Test func requestSendWaitsForUser() throws {
        let h = try Harness()
        var notified: SendRequest?
        h.gate.onSendRequested = { notified = $0 }
        let out = h.call("request_send", ["chat_id": .string(ID.mom), "text": "Running 10 min late"])
        let id = try #require(out.json["request_id"]?.string)
        #expect(notified?.id == id)
        #expect(h.sender.sent.isEmpty)
        #expect(h.call("check_send_status", ["request_id": .string(id)]).json["status"]?.string == "waiting_for_approval")
        h.gate.approve(id)
        #expect(h.sender.sent.count == 1)
        #expect(h.sender.sent.first?.0 == "Running 10 min late")
        #expect(h.sender.sent.first?.1 == "iMessage;-;+15550100001")
        #expect(h.call("check_send_status", ["request_id": .string(id)]).json["status"]?.string == "sent")
        h.gate.approve(id)   // approving twice does nothing
        #expect(h.sender.sent.count == 1)
    }

    @Test func declinedMessagesAreNotSent() throws {
        let h = try Harness()
        let id = try #require(h.call("request_send", ["chat_id": .string(ID.mom), "text": "hi"]).json["request_id"]?.string)
        h.gate.decline(id)
        h.gate.approve(id)
        #expect(h.sender.sent.isEmpty)
        #expect(h.call("check_send_status", ["request_id": .string(id)]).json["status"]?.string == "declined_by_ben")
    }

    @Test func sendNeedsItsOwnToggle() throws {
        let h = try Harness()
        #expect(h.call("request_send", ["chat_id": .string(ID.alex), "text": "hi"]).isError)
        #expect(h.call("request_send", ["chat_id": .string(ID.therapist), "text": "hi"]).isError)
        #expect(h.gate.sends.isEmpty)
    }
}

@Suite("Access log")
struct LogTests {
    @Test func everyCallIsLogged() throws {
        let h = try Harness()
        h.call("list_chats")
        h.call("read_chat", ["chat_id": .string(ID.mom)])
        h.call("read_chat", ["chat_id": .string(ID.therapist)])
        h.call("draft_reply", ["chat_id": .string(ID.alex), "text": "ok"])
        let log = h.gate.log.all
        #expect(log.map(\.tool) == ["list_chats", "read_chat", "read_chat", "draft_reply"])
        #expect(log.map(\.outcome) == [.allowed, .allowed, .denied, .allowed])
        #expect(log[1].chatName == "Mom" && log[1].summary == "Returned 9 messages")
        #expect(log[2].chatName == "Dr. Rivera")
        #expect(log.allSatisfy { $0.client == "Test" })
        // Persisted to disk too.
        let reloaded = AccessLog(url: h.dir.appendingPathComponent("access.jsonl"))
        #expect(reloaded.all.count == 4)
    }
}
