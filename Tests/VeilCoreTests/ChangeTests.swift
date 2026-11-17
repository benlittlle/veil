import Foundation
import Testing
@testable import VeilCore

/// Work is skipped when nothing changed, so these check that a real change is never missed.
@Suite("Change detection")
struct ChangeTests {
    @Test func chatListFollowsDatabaseChanges() throws {
        let h = try Harness()
        let before = try h.gate.conversations()
        #expect(try h.gate.conversations() == before)   // unchanged database: same list
        let db = try SQLiteDB(path: h.dir.appendingPathComponent("chat.db").path, readOnly: false)
        try db.query("INSERT INTO chat VALUES (?, ?, ?, ?, ?, ?)",
                     [.int(50), .text("iMessage;-;+15550100050"), .int(45), .text("+15550100050"), .text("iMessage"), .null])
        let after = try h.gate.conversations()
        #expect(after.count == before.count + 1)
        #expect(after.contains { $0.id == "+15550100050" })
        // A new chat is locked until the user opens it.
        let listed = h.call("list_chats").text
        #expect(listed.contains("+15550100050"))
        #expect(h.call("read_chat", ["chat_id": "+15550100050"]).isError)
    }

    @Test func backgroundPassJudgesNewMessages() throws {
        let f = try FilterHarness()
        f.gate.warmFilterCache()
        #expect(f.gate.filter.cachedCount == 17)
        let calls = f.fake.calls.count
        f.gate.warmFilterCache()                       // nothing changed: nothing re-sent
        #expect(f.fake.calls.count == calls)
        try f.add("late", "Running ten minutes late", hoursAgo: 0)
        f.gate.warmFilterCache()
        #expect(f.gate.filter.cachedCount == 18)
    }

    @Test func backgroundPassRetriesWhatItCouldNotFinish() throws {
        let f = try FilterHarness()
        f.fake.behavior = .error
        f.gate.warmFilterCache()
        #expect(f.gate.filter.cachedCount == 0)
        f.fake.behavior = .normal                      // the model works again; the database didn't change
        f.gate.warmFilterCache()
        #expect(f.gate.filter.cachedCount == 17)
    }

    /// The watcher's kernel sources are registered in the background after `start`, on a low-priority
    /// queue. Makes harmless writes until it reports one, so the change a test is about can't land
    /// before it's watching.
    func waitUntilWatching(_ p: PingHarness, _ changes: LockedBox<Int>) async throws {
        let before = changes.value
        let deadline = Date().addingTimeInterval(20)
        var n = 0
        while changes.value == before, Date() < deadline {
            n += 1
            try p.db.query("PRAGMA user_version = \(n)")
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(changes.value > before, "the watcher never reported a change")
    }

    @Test func pingsFollowFileEvents() async throws {
        let p = try PingHarness()
        let watcher = DatabaseWatcher(databasePath: p.h.dir.appendingPathComponent("chat.db").path, latency: 0.05)
        let changes = LockedBox(0)
        watcher.onChange { changes.set(changes.value + 1); p.notifier.poke() }
        #expect(watcher.start())
        p.notifier.start(fallback: 3600)               // only a file event can wake it in time
        defer { p.notifier.stop(); watcher.stop() }
        try await waitUntilWatching(p, changes)
        try p.incoming(chatRow: 1)
        await p.settle { p.transport.requests.count >= 1 }
        #expect(p.transport.requests.count == 1)
    }

    @Test func pingsFollowWriteAheadLogEvents() async throws {
        let p = try PingHarness()
        // Messages keeps chat.db in WAL mode, so new rows land in chat.db-wal first.
        // The log already exists and stays open, as with Messages; rows are appended to it.
        try p.db.query("PRAGMA journal_mode = WAL")
        try p.db.query("PRAGMA wal_autocheckpoint = 0")
        try p.incoming(chatRow: 1)
        p.notifier.tick()
        await p.settle { p.transport.requests.count >= 1 }
        let watcher = DatabaseWatcher(databasePath: p.h.dir.appendingPathComponent("chat.db").path, latency: 0.05)
        let changes = LockedBox(0)
        watcher.onChange { changes.set(changes.value + 1); p.notifier.poke() }
        #expect(watcher.start())
        p.notifier.start(fallback: 3600)
        defer { p.notifier.stop(); watcher.stop() }
        try await waitUntilWatching(p, changes)
        try p.incoming(chatRow: 6)
        await p.settle { p.transport.requests.count >= 2 }
        #expect(p.transport.requests.count == 2)
    }

    @Test func heldBackPingSetsTheNextWakeUp() {
        var c = PingCoalescer(interval: 60)
        let t0 = Date()
        #expect(c.nextDue == nil)
        c.add(NewMessagePing(chatID: "a", messageID: 1, receivedAt: t0))
        #expect(c.due(now: t0).count == 1)
        #expect(c.nextDue == nil)
        c.add(NewMessagePing(chatID: "a", messageID: 2, receivedAt: t0))
        #expect(c.due(now: t0.addingTimeInterval(5)).isEmpty)
        #expect(c.nextDue == t0.addingTimeInterval(60))
    }

    @Test func pingsOffMeansNoWakeUps() throws {
        let p = try PingHarness()
        p.notifier.configure(nil)
        p.notifier.start(fallback: 0.01)
        defer { p.notifier.stop() }
        try p.incoming(chatRow: 1)
        p.notifier.poke()
        Thread.sleep(forTimeInterval: 0.2)
        #expect(p.transport.requests.isEmpty)
    }
}
