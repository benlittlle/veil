import Foundation
import Testing
@testable import VeilCore

typealias Aged = DemoData.Aged

/// A clock tests can move. The gate reads the time through it for history windows and time limits.
final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ now: Date = Date()) { self.now = now }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

/// Ids of the aged fixture messages (`DemoData.addAgedHistory`), with the marker each one carries.
let agedIDs: [Int64: String] = [8001: Aged.pastDay, 8002: Aged.pastWeek, 8003: Aged.pastMonth, 8004: Aged.pastWeek,
                                8007: Aged.pastWeek, 8008: Aged.pastMonth, 8009: Aged.pastWeek]

/// "History the assistant can see": nothing older than a chat's window comes back from any tool, and
/// what's outside it gets the same answer as something that doesn't exist.
@Suite("History windows")
struct HistoryTests {
    /// Mom: everything. Alex: read, waiting, drafts, photos. Climbing: read, waiting, activity. All with window `w`.
    func harness(_ w: HistoryWindow, alex: HistoryWindow? = nil, mom: HistoryWindow? = nil) throws -> Harness {
        try Harness(access: [
            ID.mom: ChatAccess(read: true, waiting: true, draft: true, send: true, attachments: true, history: mom ?? w),
            ID.alex: ChatAccess(read: true, waiting: true, draft: true, attachments: true, history: alex ?? w),
            ID.climbing: ChatAccess(read: true, waiting: true, activity: true, history: w),
        ], aged: true)
    }

    func dates(_ msgs: [JSON], _ key: String = "time") -> [Date] {
        msgs.compactMap { $0[key]?.string.flatMap { ISO8601DateFormatter().date(from: $0) } }
    }

    /// Every tool, every chat, a range of arguments: everything the assistant could get back.
    func sweep(_ h: Harness) -> [String] {
        let ids = [ID.mom, ID.alex, ID.therapist, ID.unknown, ID.climbing, ID.family]
        var out = [h.call("list_chats").raw, h.call("waiting_on_reply", ["days": 90]).raw]
        for id in ids {
            for tool in ["read_chat", "list_attachments", "chat_activity"] { out.append(h.call(tool, ["chat_id": .string(id), "limit": 200]).raw) }
            out.append(h.call("chat_activity", ["chat_id": .string(id), "since": "2000-01-01T00:00:00Z", "limit": 200]).raw)
            for q in ["AGED", "e", "passport", "birthday"] {
                out.append(h.call("search_messages", ["query": .string(q), "chat_id": .string(id), "limit": 50]).raw)
            }
        }
        for q in ["AGED", "e", "trail", "rope"] { out.append(h.call("search_messages", ["query": .string(q), "limit": 50]).raw) }
        for a in 0...7 { out.append(h.call("get_attachment", ["attachment_id": .number(Double(a))]).raw) }
        for (id, _) in agedIDs {
            out.append(h.call("read_chat", ["chat_id": .string(ID.mom), "before_message_id": JSON(id)]).raw)
            out.append(h.call("chat_activity", ["chat_id": .string(ID.mom), "before_message_id": JSON(id)]).raw)
        }
        return out
    }

    @Test(arguments: [HistoryWindow.day, .week, .month, .sinceShared])
    func everyToolRespectsTheWindow(_ w: HistoryWindow) throws {
        let h = try harness(w)
        let outputs = sweep(h)
        let hidden = Aged.hidden(by: w)
        for o in outputs {
            for m in hidden { #expect(!o.contains(m), "\(w): \(m) leaked") }
            #expect(!o.contains(secret))
        }
        // chat_activity has no text: check by message id instead.
        for c in [ID.mom, ID.alex, ID.climbing] {
            let ids = h.call("chat_activity", ["chat_id": .string(c), "limit": 200]).json["messages"]?.array?.compactMap { $0["id"]?.int } ?? []
            for (id, marker) in agedIDs where hidden.contains(marker) { #expect(!ids.contains(Int(id)), "\(w): activity \(id) leaked") }
        }
        // And what's inside the window still comes through.
        let mom = h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200]).raw
        for m in Aged.all where !hidden.contains(m) { #expect(mom.contains(m) || m == Aged.pastMonth, "\(w): \(m) missing") }
        if w == .day || w == .week || w == .month { #expect(mom.contains("Call me when you can")) }
        // The log never holds message text.
        let log = h.gate.log.all.map(\.summary).joined(separator: "\n")
        for m in Aged.all { #expect(!log.contains(m)) }
    }

    @Test func allIsTheDefaultAndShowsEverything() throws {
        let h = try Harness(aged: true)
        #expect(h.gate.permissions.state.chats[ID.mom]?.history == .all)
        let mom = h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200])
        for m in Aged.all { #expect(mom.raw.contains(m)) }
        #expect(mom.json["history"] == nil)
        #expect(h.call("list_chats").json["chats"]?.array?.allSatisfy { $0["history"] == nil } == true)
    }

    @Test func existingLeakSweepStillHoldsWithOlderHistory() throws {
        // The standard leak sweep, with the aged fixture added and every window in turn.
        for w in HistoryWindow.allCases {
            let h = try harness(w)
            for o in sweep(h) { #expect(!o.contains(secret)) }
        }
    }

    @Test func readChatPagesStopAtTheWindow() throws {
        let h = try harness(.day)
        let cutoff = Date().addingTimeInterval(-86_400)
        // limit 1, following the cursor all the way.
        var seen: [Int] = []
        var cursor: JSON?
        for _ in 0..<20 {
            var args: [String: JSON] = ["chat_id": .string(ID.mom), "limit": 1]
            if let cursor { args["before_message_id"] = cursor }
            let page = h.call("read_chat", .object(args)).json
            let msgs = page["messages"]?.array ?? []
            #expect(dates(msgs).allSatisfy { $0 >= cutoff.addingTimeInterval(-1) })
            seen += msgs.compactMap { $0["id"]?.int }
            cursor = page["older_messages_cursor"]
            if cursor == nil { break }
        }
        // 3h, 21h, 22h and 23h old: four messages inside the last 24 hours, nothing older.
        #expect(seen.count == 4 && Set(seen).count == 4)
        for (id, _) in agedIDs { #expect(!seen.contains(Int(id))) }
        // A full page right at the edge gives a cursor, and the page after it is simply empty.
        let full = h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 4]).json
        let edge = try #require(full["older_messages_cursor"])
        let after = h.call("read_chat", ["chat_id": .string(ID.mom), "before_message_id": edge]).json
        #expect(after["messages"]?.array?.isEmpty == true)
        #expect(after["older_messages_cursor"] == nil)
        // A cursor pointing outside the window gets exactly what a made-up id gets.
        let made = h.call("read_chat", ["chat_id": .string(ID.mom), "before_message_id": 999_999])
        for (id, _) in agedIDs {
            let out = h.call("read_chat", ["chat_id": .string(ID.mom), "before_message_id": JSON(id)])
            #expect(!out.isError)
            #expect(out.json["messages"] == made.json["messages"])
        }
        // The assistant is told the window, not what's hidden.
        #expect(full["history"]?.string == "This chat shares the last 24 hours only.")
    }

    @Test func chatActivityRespectsTheWindowWhateverSinceSays() throws {
        let h = try harness(.week)
        let cutoff = Date().addingTimeInterval(-7 * 86_400)
        let out = h.call("chat_activity", ["chat_id": .string(ID.mom), "since": "2000-01-01T00:00:00Z", "limit": 200]).json
        let msgs = out["messages"]?.array ?? []
        #expect(!msgs.isEmpty)
        #expect(dates(msgs).allSatisfy { $0 >= cutoff.addingTimeInterval(-1) })
        // Paging back with limit 1 also ends at the window.
        var cursor: JSON?, count = 0
        for _ in 0..<40 {
            var args: [String: JSON] = ["chat_id": .string(ID.mom), "limit": 1]
            if let cursor { args["before_message_id"] = cursor }
            let page = h.call("chat_activity", .object(args)).json
            count += page["messages"]?.array?.count ?? 0
            cursor = page["older_messages_cursor"]
            if cursor == nil { break }
        }
        #expect(count == msgs.count)
        // A chat with nothing inside its window looks like a chat nobody has written in.
        let quiet = try harness(.week, alex: .sinceShared)
        let alex = quiet.call("chat_activity", ["chat_id": .string(ID.alex)]).json
        #expect(alex["messages"]?.array?.isEmpty == true)
        #expect(alex["last_incoming_at"] == .null && alex["last_reply_at"] == .null && alex["replied_since_last_incoming"] == .null)
        #expect(alex["history"]?.string == "This chat shares only messages since the user shared it.")
    }

    @Test func searchOnlyFindsMessagesInsideEachChatsWindow() throws {
        let h = try harness(.week, alex: .all)
        let hits = h.call("search_messages", ["query": "AGED", "limit": 50]).json["results"]?.array ?? []
        let texts = hits.compactMap { $0["message"]?["text"]?.string }
        // Mom and Climbing: last 7 days, so only the 2-day-old one. Alex shares everything.
        #expect(texts.contains { $0.hasPrefix(Aged.pastDay) })
        #expect(hits.filter { $0["chat_id"]?.string != ID.alex }.allSatisfy { !$0.encoded().contains(Aged.pastWeek) && !$0.encoded().contains(Aged.pastMonth) })
        #expect(texts.contains("\(Aged.pastWeek) Here's the trail map") && texts.contains("\(Aged.pastMonth) Welcome to the club"))
        #expect(h.call("search_messages", ["query": "passport", "chat_id": .string(ID.mom)]).json["results"]?.array?.isEmpty == true)
        #expect(h.call("search_messages", ["query": "rope"]).json["results"]?.array?.isEmpty == true)
    }

    @Test func waitingOnReplyOnlyLooksInsideTheWindow() throws {
        let h = try harness(.day, alex: .sinceShared)
        let waiting = h.call("waiting_on_reply", ["days": 90]).json["waiting"]?.array ?? []
        // Alex's last message (6 hours ago) is from before the chat was shared: not waiting.
        #expect(!waiting.contains { $0["chat_id"]?.string == ID.alex })
        let mom = try #require(waiting.first { $0["chat_id"]?.string == ID.mom })
        #expect(mom["last_message"]?.string == "Call me when you can")
    }

    @Test func replyQuotesFollowTheWindow() throws {
        func quote(_ w: HistoryWindow) throws -> JSON? {
            let h = try harness(w)
            let msgs = h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200]).json["messages"]?.array ?? []
            let reply = try #require(msgs.first { $0["text"]?.string == "Found it, thanks" })
            return reply["reply_to"]
        }
        #expect(try quote(.week) == nil)                 // the 10-day-old original is outside the window
        #expect(try quote(.day) == nil)
        #expect(try quote(.month)?["text"]?.string?.hasPrefix(Aged.pastWeek) == true)
        #expect(try quote(.all)?["text"]?.string?.hasPrefix(Aged.pastWeek) == true)
    }

    @Test func listChatsHidesLastActivityOutsideTheWindow() throws {
        let h = try harness(.day, mom: .sinceShared)
        let chats = h.call("list_chats").json["chats"]?.array ?? []
        let mom = try #require(chats.first { $0["chat_id"]?.string == ID.mom })
        #expect(mom["last_activity"] == nil)
        #expect(mom["history"]?.string == "This chat shares only messages since the user shared it.")
        let alex = try #require(chats.first { $0["chat_id"]?.string == ID.alex })
        #expect(alex["last_activity"] != nil)
        #expect(alex["history"]?.string == "This chat shares the last 24 hours only.")
        // Mom sorts by name with the chats that show no activity, so the order can't hint at when she last wrote.
        let names = chats.filter { $0["last_activity"] == nil }.compactMap { $0["name"]?.string }
        #expect(names == names.sorted { $0.lowercased() < $1.lowercased() } && names.contains("Mom"))
    }

    @Test func sharedAttachmentsNeedEveryChatsWindowToIncludeThem() throws {
        // Attachment 6 is in a recent Mom message and a 10-day-old Alex message. Both chats allow photos.
        let open = try harness(.all)
        #expect(!open.call("get_attachment", ["attachment_id": 6]).isError)
        #expect(open.call("list_attachments", ["chat_id": .string(ID.mom)]).json["attachments"]?.array?.contains { $0["attachment_id"]?.int == 6 } == true)

        let h = try harness(.all, alex: .week)
        let unavailable = h.call("get_attachment", ["attachment_id": 99_999]).text
        let six = h.call("get_attachment", ["attachment_id": 6])
        #expect(six.isError && six.text == unavailable)
        let momList = h.call("list_attachments", ["chat_id": .string(ID.mom), "limit": 100]).json["attachments"]?.array ?? []
        #expect(!momList.contains { $0["attachment_id"]?.int == 6 })
        #expect(momList.contains { $0["attachment_id"]?.int == 1 })
        let read = h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200])
        #expect(!read.raw.contains("\(Aged.pastWeek)-trail"))
        let msg = try #require(read.json["messages"]?.array?.first { $0["text"]?.string == "Is this the one Alex sent?" })
        #expect(msg["attachments_hidden"]?.int == 1)
        #expect(h.call("list_attachments", ["chat_id": .string(ID.alex)]).json["attachments"]?.array?.isEmpty == true)

        // Mom's own window: the 10-day-old beach photo (attachment 5) is gone, the recent garden photo isn't.
        let w = try harness(.week)
        #expect(w.call("get_attachment", ["attachment_id": 5]).text == unavailable)
        #expect(!w.call("get_attachment", ["attachment_id": 1]).isError)
        let list = w.call("list_attachments", ["chat_id": .string(ID.mom), "limit": 100]).json["attachments"]?.array?.compactMap { $0["attachment_id"]?.int } ?? []
        #expect(list.contains(1) && !list.contains(5) && !list.contains(6))
    }

    @Test func sinceSharedShowsOnlyWhatArrivesAfterSharing() throws {
        let h = try harness(.sinceShared)
        #expect(h.call("read_chat", ["chat_id": .string(ID.mom)]).json["messages"]?.array?.isEmpty == true)
        let db = try SQLiteDB(path: h.dir.appendingPathComponent("chat.db").path, readOnly: false)
        let d = appleTimestamp(Date().addingTimeInterval(2))
        try db.query("INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me) VALUES (9500, 'NEW-9500', 'Fresh news', 1, ?, 0)", [.int(d)])
        try db.query("INSERT INTO chat_message_join VALUES (1, 9500, ?)", [.int(d)])
        let msgs = h.call("read_chat", ["chat_id": .string(ID.mom)]).json["messages"]?.array ?? []
        #expect(msgs.compactMap { $0["text"]?.string } == ["Fresh news"])
    }

    @Test func sharedSinceIsRecordedAndKept() throws {
        let h = try Harness(access: [:])
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000.7))
        h.gate.clock = { clock.now }
        func since() -> Date? { h.gate.permissions.state.chats[ID.mom]?.sharedSince }
        #expect(since() == nil)
        try h.gate.setSwitches([\.read: true], for: ID.mom)
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(since() == t0)
        // More switches, a different window, the filter: the time stays.
        clock.advance(3600)
        try h.gate.setSwitches([\.draft: true, \.read: false], for: ID.mom)
        try h.gate.setHistory(.week, for: ID.mom)
        try h.gate.setFiltered(true, for: ID.mom)
        try h.gate.setAccess(ChatAccess(read: true, draft: true, filtered: true, history: .week), for: ID.mom)
        #expect(since() == t0)
        // Signed with everything else.
        let reloaded = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        #expect(reloaded.integrity == .ok && reloaded.state.chats[ID.mom]?.sharedSince == t0)
        // Nothing shared: forgotten. Shared again: the new time.
        try h.gate.setSwitches([\.read: false, \.draft: false], for: ID.mom)
        #expect(since() == nil)
        clock.advance(60)
        try h.gate.setSwitches([\.activity: true], for: ID.mom)
        #expect(since() == t0.addingTimeInterval(3660))
        // Hiding keeps the switches underneath, so the time stays too.
        try h.gate.setSwitches([\.hidden: true], for: ID.mom)
        #expect(since() == t0.addingTimeInterval(3660))
        // The settings tools go through the same path.
        try h.gate.setAgentSettings(.direct)
        clock.advance(60)
        #expect(h.call("change_chat_settings", ["chat_id": .string(ID.alex), "read": true]).json["status"]?.string == "applied")
        #expect(h.gate.permissions.state.chats[ID.alex]?.sharedSince == t0.addingTimeInterval(3720))
    }

    @Test func pingsOutsideTheWindowAreSuppressed() async throws {
        let p = try PingHarness(access: [ID.mom: ChatAccess(read: true, history: .sinceShared)])
        // Arrived (or synced) with a time from before the chat was shared: never announced.
        try p.incoming(chatRow: 1, text: "Older news", date: Date().addingTimeInterval(-600))
        p.notifier.tick()
        await p.settle { !p.transport.requests.isEmpty }
        #expect(p.transport.requests.isEmpty)
        let fresh = try p.incoming(chatRow: 1, text: "Fresh news", date: Date().addingTimeInterval(1))
        p.notifier.tick()
        await p.settle { !p.transport.requests.isEmpty }
        #expect(p.transport.requests.count == 1)
        #expect((p.bodies.first?["message_id"] as? NSNumber)?.int64Value == fresh)
    }

    @Test func backgroundFilterWorkSkipsMessagesOutsideTheWindow() throws {
        let f = try FilterHarness(access: [ID.mom: ChatAccess(read: true, filtered: true, history: .week)])
        try DemoData.addAgedHistory(db: f.h.dir.appendingPathComponent("chat.db"))
        f.gate.warmFilterCache()
        // The model is sent text (in pieces with their own ids), so check what it was shown.
        let judged = f.fake.calls.flatMap { $0 }.map(\.text).joined(separator: "\n")
        #expect(judged.contains("Call me when you can"))
        for m in Aged.hidden(by: .week) { #expect(!judged.contains(m), "judged \(m)") }
        #expect(judged.contains(Aged.pastDay))       // 2 days old: inside the window
        // The user's review screen shows what the assistant could see, so it stays inside the window too.
        let review = try f.gate.filterReview(chatID: ID.mom)
        #expect(review.allSatisfy { agedIDs[$0.id].map { !Aged.hidden(by: .week).contains($0) } ?? true })
    }

    @Test func backgroundPhotoChecksSkipPhotosOutsideTheWindow() async throws {
        var mom = PhotoHarness.momFiltered[ID.mom]!
        mom.history = .week
        let p = try PhotoHarness(access: [ID.mom: mom])
        try DemoData.addAgedHistory(db: p.f.h.dir.appendingPathComponent("chat.db"))
        p.gate.warmFilterCache()
        let store = try p.gate.messagesStore()
        func cached(_ id: Int64) throws -> Bool {
            let info = try #require(try store.attachment(id: id))
            return p.gate.photos.cached(PhotoChecker.Request(id: id, url: try #require(store.safeFileURL(for: info)))) != nil
        }
        for _ in 0..<300 where !(try cached(1)) { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(try cached(1))
        #expect(try !cached(5))              // 10 days old: never checked
        #expect(p.image.calls == 1)
    }
}
