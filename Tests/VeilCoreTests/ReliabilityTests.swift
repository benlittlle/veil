import Foundation
import Testing
@testable import VeilCore

/// Regressions for correctness and reliability bugs a user would hit in everyday use.
@Suite("Reliability")
struct ReliabilityTests {
    // MARK: Content filter

    @Test func veryLongMessagesDontTieUpTheModel() throws {
        let f = try FilterHarness()
        // A pasted document: far more than one model batch.
        let huge = String(repeating: "Notes from the long planning call, nothing private here. ", count: 300)
        #expect(huge.count > ContentFilter.maxJudgedChars)
        // Just under the limit: still judged, in pieces.
        let near = String(repeating: "Ordinary words for a longer update. ", count: 200)
        #expect(near.count <= ContentFilter.maxJudgedChars && near.count > ContentFilter.maxModelChars)
        try f.add("huge", huge, hoursAgo: 0.2)
        try f.add("near", near, hoursAgo: 0.1)

        // Fails closed: no verdict, so withheld, without ever being sent to the model.
        #expect(f.text(of: "huge") == "[withheld]")
        #expect(f.text(of: "near") == near.trimmingCharacters(in: .whitespaces))
        #expect(!f.fake.calls.flatMap { $0 }.contains { $0.text.contains("planning call") })

        // Background passes never send it either, so the model isn't kept busy pass after pass.
        f.gate.warmFilterCache()
        let calls = f.fake.calls.count
        f.gate.warmFilterCache()
        #expect(f.fake.calls.count == calls)
        #expect(!f.fake.calls.flatMap { $0 }.contains { $0.text.contains("planning call") })

        // The user sees why in the review screen, and can let it through.
        let item = try #require(try f.gate.filterReview(chatID: ID.alex).first { $0.id == f.ids["huge"] })
        #expect(item.withheld && item.notCleared)
        try f.gate.setFilterAllowed(true, message: try #require(f.ids["huge"]), in: ID.alex)
        #expect(f.text(of: "huge") == huge.trimmingCharacters(in: .whitespaces))
    }

    @Test func veryLongMessagesPassWhenNoTopicNeedsTheModel() throws {
        let f = try FilterHarness()
        var p = FilterPolicy.standard
        for c in FilterCategory.modelCategories { p.set(c, .allow) }
        try f.gate.setChatFilterPolicy(p, for: ID.alex)
        let huge = String(repeating: "Notes from the long planning call, nothing private here. ", count: 300)
        try f.add("huge", huge, hoursAgo: 0.1)
        #expect(f.text(of: "huge") == huge.trimmingCharacters(in: .whitespaces))
        #expect(f.fake.calls.isEmpty)
    }

    // MARK: Watching chat.db

    @Test func watcherPicksUpTheDatabaseOnceItCanBeOpened() async throws {
        // Before Full Disk Access, the Messages folder can't be opened at all; here it doesn't exist yet.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("veil-watch-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("chat.db").path
        let watcher = DatabaseWatcher(databasePath: path, latency: 0.05)
        let changes = LockedBox(0)
        watcher.onChange { changes.set(changes.value + 1) }
        #expect(!watcher.start())
        defer { watcher.stop() }

        // Now it can be: starting again watches it, without a relaunch.
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: path, readOnly: false)
        try db.query("CREATE TABLE t (x INTEGER)")
        #expect(watcher.start())
        let deadline = Date().addingTimeInterval(20)
        var n = 0
        while changes.value == 0, Date() < deadline {
            n += 1
            try db.query("INSERT INTO t VALUES (?)", [.int(Int64(n))])
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(changes.value > 0)
    }

    // MARK: Failed sends

    /// A stand-in for osascript that prints an error and fails. It never reaches Messages.
    func fakeOsascript(_ stderr: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("osascript-\(UUID().uuidString.prefix(6))")
        let quoted = stderr.replacingOccurrences(of: "'", with: "'\\''")
        try Data("#!/bin/sh\nprintf '%s\\n' '\(quoted)' >&2\nexit 1\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @Test func failedSendsSayWhatToDoAndNeverEchoTheMessage() throws {
        let h = try Harness()
        let cases: [(String, String)] = [
            ("0:91: execution error: Not authorized to send Apple events to Messages. (-1743)", AppleScriptSender.notAllowed),
            ("0:91: execution error: Messages got an error: Can't get chat id \"iMessage;-;+15550100001\". (-1728)", "couldn't find this chat"),
            ("0:91: execution error: Messages got an error: AppleEvent timed out. (-1712)", "can't tell whether it went out"),
            ("0:91: execution error: Can't make \"SECRET plan for Saturday\" into type text. (-1700)", "(error -1700)"),
            ("something unexpected about SECRET", "Messages couldn't send it."),
        ]
        for (stderr, expected) in cases {
            let sender = AppleScriptSender(osascript: try fakeOsascript(stderr, in: h.dir))
            #expect(throws: (any Error).self) { try sender.send("SECRET plan for Saturday", toChatGUID: "iMessage;-;+15550100001") }
            do { try sender.send("SECRET plan for Saturday", toChatGUID: "iMessage;-;+15550100001") } catch {
                let reason = error.localizedDescription
                #expect(reason.contains(expected), "\(reason)")
                #expect(!reason.contains("SECRET") && !reason.contains("+1555"), "\(reason)")
            }
        }
    }

    @Test func anApprovedSendThatFailsIsReportedPlainly() throws {
        let h = try Harness()
        let sender = AppleScriptSender(osascript: try fakeOsascript("execution error: Not authorized to send Apple events to Messages. (-1743)", in: h.dir))
        let gate = Gate(permissions: h.gate.permissions, log: AccessLog(url: nil), contacts: StaticContacts(DemoData.contacts),
                        sender: sender, openStore: { try h.gate.messagesStore() })
        let req = Harness.Out(result: gate.call(tool: "request_send", arguments: ["chat_id": .string(ID.mom), "text": "SECRET see you soon"], client: "t"))
        let id = try #require(req.json["request_id"]?.string)
        gate.approve(id)
        #expect(gate.sends.first?.status == .failed(AppleScriptSender.notAllowed))
        let status = Harness.Out(result: gate.call(tool: "check_send_status", arguments: ["request_id": .string(id)], client: "t")).text
        #expect(status.contains("Automation") && !status.contains("SECRET"))
        #expect(gate.log.all.contains { $0.outcome == .failed && $0.summary.contains("Automation") })
        #expect(!gate.log.all.contains { $0.summary.contains("SECRET") })
    }

    // MARK: Edited and unsent messages

    /// Adds the edit and unsend columns newer chat.db files have, and messages to Mom's chat (row 1).
    final class EditHarness {
        let h: Harness
        let db: SQLiteDB
        private var nextID: Int64 = 30_000
        init(access: [String: ChatAccess] = Harness.defaultAccess) throws {
            h = try Harness(access: access)
            db = try SQLiteDB(path: h.dir.appendingPathComponent("chat.db").path, readOnly: false)
            try db.query("ALTER TABLE message ADD COLUMN date_edited INTEGER DEFAULT 0")
            try db.query("ALTER TABLE message ADD COLUMN date_retracted INTEGER DEFAULT 0")
        }
        @discardableResult
        func add(text: String?, body: String?, edited: Bool = false, unsent: Bool = false, minutesAgo: Double = 5) throws -> Int64 {
            nextID += 1
            let date = appleTimestamp(Date().addingTimeInterval(-minutesAgo * 60))
            let later = appleTimestamp(Date())
            try db.query("""
                INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me, date_edited, date_retracted)
                VALUES (?,?,?,?,1,?,0,?,?)
                """, [.int(nextID), .text("EDIT-\(nextID)"), text.map { .text($0) } ?? .null,
                      body.map { .blob(DemoData.archived($0)) } ?? .null, .int(date),
                      .int(edited ? later : 0), .int(unsent ? later : 0)])
            try db.query("INSERT INTO chat_message_join VALUES (1, ?, ?)", [.int(nextID), .int(date)])
            return nextID
        }
        func text(of id: Int64) -> String? {
            let msgs = h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200]).json["messages"]?.array ?? []
            return msgs.first { $0["id"]?.int.map(Int64.init) == id }?["text"]?.string
        }
    }

    @Test func editedMessagesShowOnlyTheirCurrentText() throws {
        let e = try EditHarness()
        // The text column still holds the first version; attributedBody has the edit.
        let edited = try e.add(text: "SECRET first version", body: "Running late, sorry", edited: true)
        // An edit with no attributedBody at all: the text column is all there is.
        let plain = try e.add(text: "See you at noon", body: nil, edited: true, minutesAgo: 4)
        // An edit whose attributedBody can't be read gets no text rather than the older version.
        let unreadable = try e.add(text: "SECRET older text", body: nil, edited: true, minutesAgo: 3)
        try e.db.query("UPDATE message SET attributedBody = ? WHERE ROWID = ?", [.blob(Data([1, 2, 3])), .int(unreadable)])

        #expect(e.text(of: edited) == "Running late, sorry")
        #expect(e.text(of: plain) == "See you at noon")
        #expect(e.text(of: unreadable) == nil)
        let read = e.h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200]).raw
        #expect(!read.contains("SECRET"))

        // Search sees the current text only.
        #expect(e.h.call("search_messages", ["query": "first version"]).json["results"]?.array?.isEmpty == true)
        #expect(e.h.call("search_messages", ["query": "older text"]).json["results"]?.array?.isEmpty == true)
        let found = e.h.call("search_messages", ["query": "running late"]).json["results"]?.array ?? []
        let ids = found.compactMap { $0["message"]?["id"]?.int }
        #expect(ids.contains(Int(edited)))
        // Non-ASCII queries take the other path through search; the result is the same.
        #expect(e.h.call("search_messages", ["query": "first versión"]).json["results"]?.array?.isEmpty == true)
    }

    @Test func unsentMessagesHaveNoText() throws {
        let e = try EditHarness()
        let unsent = try e.add(text: "SECRET I shouldn't have sent this", body: "SECRET I shouldn't have sent this", unsent: true)
        let msgs = e.h.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200])
        #expect(!msgs.raw.contains("SECRET"))
        #expect(msgs.json["messages"]?.array?.contains { $0["id"]?.int == Int(unsent) } == true)   // still there, without text
        #expect(e.text(of: unsent) == nil)
        #expect(e.h.call("search_messages", ["query": "have sent"]).json["results"]?.array?.isEmpty == true)
        #expect(!e.h.call("waiting_on_reply").raw.contains("SECRET"))
    }

    @Test func olderDatabasesWithoutEditColumnsStillRead() throws {
        // The standard fixture has no edit columns, like chat.db before macOS 13.
        let h = try Harness()
        let msgs = h.call("read_chat", ["chat_id": .string(ID.mom)])
        #expect(!msgs.isError)
        let list = msgs.json["messages"]?.array ?? []
        #expect(list.count > 0)
        #expect(!h.call("search_messages", ["query": "dinner"]).isError)
    }
}
