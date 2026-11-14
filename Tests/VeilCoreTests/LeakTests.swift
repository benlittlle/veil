import Foundation
import Testing
@testable import VeilCore

/// Proves that chats the user hasn't allowed never leak through any tool.
@Suite("Blocked chats never leak")
struct LeakTests {
    @Test func listChatsShowsOnlyNameAndNumberForLockedChats() throws {
        let h = try Harness()
        let out = h.call("list_chats")
        #expect(!out.isError)
        #expect(!out.raw.contains(secret))
        let chats = out.json["chats"]?.array ?? []
        #expect(chats.count == 6)   // Mom's iMessage + SMS rows are one conversation
        for id in [ID.therapist, ID.family, ID.unknown] {
            let c = try #require(chats.first { $0["chat_id"]?.string == id })
            #expect(c["allowed"] == .array([]))
            #expect(c["last_activity"] == nil)
            let keys = Set(c.objectKeys)
            #expect(keys == ["chat_id", "name", "type", "participants", "allowed", "note"])
        }
        let unknown = chats.first { $0["chat_id"]?.string == ID.unknown }
        #expect(unknown?["participants"]?.array?.first?["handle"]?.string == "+15550199999")
        #expect(chats.first { $0["chat_id"]?.string == ID.therapist }?["name"]?.string == "Dr. Rivera")
    }

    @Test func readingLockedChatsIsRefused() throws {
        let h = try Harness()
        for id in [ID.therapist, ID.family, ID.unknown, "+15550100004", "chat999", "' OR 1=1 --"] {
            let out = h.call("read_chat", ["chat_id": .string(id), "limit": 200])
            #expect(out.isError, "read_chat \(id) should be refused")
            #expect(!out.raw.contains(secret))
        }
    }

    @Test func readChatNeverIncludesOtherChats() throws {
        let h = try Harness()
        for id in [ID.mom, ID.alex, ID.climbing] {
            let out = h.call("read_chat", ["chat_id": .string(id), "limit": 200])
            #expect(!out.isError)
            #expect(!out.raw.contains(secret), "\(id) leaked")
        }
    }

    @Test func searchOnlyCoversAllowedChats() throws {
        let h = try Harness()
        for q in ["SECRET", "surprise party", "cake", "session notes", "4417", "Jordan"] {
            let out = h.call("search_messages", ["query": .string(q), "limit": 50])
            let results = out.json["results"]?.array ?? []
            #expect(results.allSatisfy { !($0.encoded().contains(secret)) }, "search \(q) leaked")
            #expect(results.allSatisfy { [ID.mom, ID.alex, ID.climbing].contains($0["chat_id"]?.string ?? "") })
        }
        #expect(h.call("search_messages", ["query": "surprise party"]).json["results"]?.array?.isEmpty == true)
        // Searching a locked chat directly is refused.
        #expect(h.call("search_messages", ["query": "party", "chat_id": .string(ID.family)]).isError)
        #expect(h.call("search_messages", ["query": "notes", "chat_id": .string(ID.therapist)]).isError)
    }

    @Test func searchRespectsReadEvenWhenOtherTogglesAreOn() throws {
        // Waiting/draft/send/attachments on, read off: still no message text via search.
        let h = try Harness(access: [ID.family: ChatAccess(read: false, waiting: true, draft: true, send: true, attachments: true)])
        let out = h.call("search_messages", ["query": "SECRET"])
        #expect(out.json["results"]?.array?.isEmpty == true)
        #expect(h.call("read_chat", ["chat_id": .string(ID.family)]).isError)
    }

    @Test func replyThreadsDoNotQuoteBlockedChats() throws {
        let h = try Harness()
        let msgs = h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200]).json["messages"]?.array ?? []
        let soundsGood = try #require(msgs.first { $0["text"]?.string == "Sounds good" })
        #expect(soundsGood["reply_to"] == nil, "reply_to resolved into a blocked chat")
        // A reply inside the same chat still works.
        let beautiful = try #require(msgs.first { $0["text"]?.string == "Beautiful!" })
        #expect(beautiful["reply_to"]?["text"]?.string == "Here's the garden")
    }

    @Test func tapbacksQuotingTextAreNotReturned() throws {
        let h = try Harness()
        let out = h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200])
        #expect(!out.raw.contains("Loved"))
    }

    @Test func groupMembershipDoesNotBridgeChats() throws {
        // Sam is in the allowed Climbing group and the blocked Family group; Mom is in the blocked group too.
        let h = try Harness()
        let climbing = h.call("read_chat", ["chat_id": .string(ID.climbing), "limit": 200])
        let texts = climbing.json["messages"]?.array?.compactMap { $0["text"]?.string } ?? []
        #expect(texts == ["New route set at the gym", "I'm in for Thursday", "Same"])
        let mom = h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200])
        #expect(!mom.raw.contains("surprise"))
        // Sam has no 1:1 chat, so his handle is not a valid way in.
        #expect(h.call("read_chat", ["chat_id": "+15550100004"]).isError)
        #expect(h.call("list_attachments", ["chat_id": "+15550100004"]).isError)
    }

    @Test func attachmentsFromBlockedChatsAreRefused() throws {
        let h = try Harness()
        for id in [2, 3, 4_000, -1] {
            let out = h.call("get_attachment", ["attachment_id": .number(Double(id))])
            #expect(out.isError, "attachment \(id) should be refused")
            #expect(!out.raw.contains(secret))
        }
        // Attachment 3 is shared by a Mom message and a blocked-chat message: it stays hidden in Mom's chat too.
        let mom = h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200])
        #expect(!mom.raw.contains("SECRET-shared"))
        #expect(mom.raw.contains("attachments_hidden"))
        let list = h.call("list_attachments", ["chat_id": .string(ID.mom)])
        #expect(!list.raw.contains(secret))
        #expect(list.json["attachments"]?.array?.compactMap { $0["attachment_id"]?.int }.contains(1) == true)
    }

    @Test func allowedPhotoIsReturnedAsImage() throws {
        let h = try Harness()
        let out = h.call("get_attachment", ["attachment_id": 1])
        #expect(!out.isError)
        #expect(out.result.content.contains { $0["type"]?.string == "image" && $0["mimeType"]?.string == "image/jpeg" })
    }

    @Test func attachmentPathsCannotEscapeTheAttachmentsFolder() throws {
        let h = try Harness()
        let out = h.call("get_attachment", ["attachment_id": 4])
        #expect(!out.raw.contains("root:"))
        #expect(!out.raw.contains("\"text\":\"##"))
    }

    @Test func attachmentsToggleHidesNamesInsideReadableChats() throws {
        let h = try Harness(access: [ID.mom: ChatAccess(read: true)])
        let out = h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200])
        #expect(!out.raw.contains("garden.png"))
        #expect(out.raw.contains("attachments_hidden"))
        #expect(h.call("get_attachment", ["attachment_id": 1]).isError)
        #expect(h.call("list_attachments", ["chat_id": .string(ID.mom)]).isError)
    }

    @Test func waitingOnReplyRespectsEachChat() throws {
        let h = try Harness(access: [
            ID.alex: ChatAccess(waiting: true),                // waiting only: no text
            ID.mom: ChatAccess(read: true, waiting: true),     // waiting + read: includes text
            ID.therapist: ChatAccess(read: true),              // read only: not flagged
        ])
        let waiting = h.call("waiting_on_reply").json["waiting"]?.array ?? []
        let ids = waiting.compactMap { $0["chat_id"]?.string }
        #expect(Set(ids) == [ID.alex, ID.mom])
        let alex = try #require(waiting.first { $0["chat_id"]?.string == ID.alex })
        #expect(alex["last_message"] == nil)
        #expect(alex["last_message_from"]?.string == "Alex Chen")
        let mom = try #require(waiting.first { $0["chat_id"]?.string == ID.mom })
        #expect(mom["last_message"]?.string == "Call me when you can")
    }

    @Test func hiddenChatsAreInvisible() throws {
        let h = try Harness(access: [ID.therapist: ChatAccess(read: true, hidden: true)])
        #expect(!h.call("list_chats").raw.contains(ID.therapist))
        let out = h.call("read_chat", ["chat_id": .string(ID.therapist)])
        #expect(out.isError && out.text.contains("No chat with that chat_id"))
    }

    @Test func noOutputAnywhereContainsPrivateText() throws {
        // Sweep every tool with every chat id and a range of arguments.
        let h = try Harness()
        let ids = [ID.mom, ID.alex, ID.therapist, ID.unknown, ID.climbing, ID.family]
        var outputs: [String] = []
        outputs.append(h.call("list_chats").raw)
        outputs.append(h.call("waiting_on_reply", ["days": 90]).raw)
        for id in ids {
            for tool in ["read_chat", "list_attachments"] { outputs.append(h.call(tool, ["chat_id": .string(id), "limit": 200]).raw) }
            outputs.append(h.call("search_messages", ["query": "e", "chat_id": .string(id), "limit": 50]).raw)
        }
        for a in 0...6 { outputs.append(h.call("get_attachment", ["attachment_id": .number(Double(a))]).raw) }
        for o in outputs { #expect(!o.contains(secret)) }
        // And the access log only holds summaries, never message text.
        let log = h.gate.log.all.map { "\($0.summary) \($0.chatName ?? "")" }.joined(separator: "\n")
        #expect(!log.contains(secret))
        #expect(!log.contains("Call me when you can"))
    }
}

extension JSON {
    var objectKeys: [String] { if case .object(let o) = self { return Array(o.keys) }; return [] }
}
