import Foundation
import Testing
@testable import VeilCore

/// A secret store whose saves can be made to fail, to prove a time limit holds even when the lock can't be written.
final class FlakySecretStore: SecretStore {
    var stored: (Data, UInt64)?
    var failSaves = false
    struct Failure: Error {}
    init(copying other: MemorySecretStore) { stored = other.stored }
    func load() throws -> (Data, UInt64)? { stored }
    func save(key: Data, generation: UInt64) throws { if failSaves { throw Failure() }; stored = (key, generation) }
}

/// Time-limited sharing: when the time runs out the chat locks, whether or not the timer or the app was running.
@Suite("Time-limited sharing")
struct ExpiryTests {
    /// Mom shares everything, with a draft and a waiting send, for one hour from `clock.now`.
    func sharedForAnHour() throws -> (Harness, TestClock) {
        let h = try Harness()
        let clock = TestClock()
        h.gate.clock = { clock.now }
        try h.gate.setFiltered(true, for: ID.mom)
        try h.gate.setHistory(.week, for: ID.mom)
        #expect(!h.call("draft_reply", ["chat_id": .string(ID.mom), "text": "Draft for later"]).isError)
        #expect(h.call("request_send", ["chat_id": .string(ID.mom), "text": "Waiting to go"]).json["status"]?.string == "waiting_for_approval")
        // Auto-send on after the waiting send, so nothing goes out on its own here.
        try h.gate.setSwitches([\.autoSend: true], for: ID.mom)
        try h.gate.setShareExpiry(ShareDuration.hour.expiry(from: clock.now), for: ID.mom)
        #expect(h.gate.permissions.state.access(ID.mom, now: clock.now).autoSend)
        return (h, clock)
    }

    func endedEntries(_ h: Harness) -> [LogEntry] { h.gate.log.all.filter { $0.tool == "share_ended" } }

    func expectLocked(_ h: Harness) {
        let a = h.gate.permissions.state.chats[ID.mom] ?? .none
        #expect(!a.hasAnySwitch && !a.autoSend && a.expires == nil && a.sharedSince == nil)
        // The filter and the history choice are kept, like "Turn everything off".
        #expect(a.filtered && a.history == .week)
        #expect(h.gate.drafts.filter { $0.chatID == ID.mom }.isEmpty)
        #expect(h.gate.sends.filter { $0.chatID == ID.mom }.allSatisfy { $0.status != .waiting })
    }

    @Test func expiryLocksPurgesAndLogsOnTheNextRequest() throws {
        let (h, clock) = try sharedForAnHour()
        #expect(!h.call("read_chat", ["chat_id": .string(ID.mom)]).isError)
        clock.advance(3601)
        // No timer has run: the request itself finds the time is up.
        let out = h.call("read_chat", ["chat_id": .string(ID.mom)])
        #expect(out.isError && out.text.contains("doesn't allow reading"))
        expectLocked(h)
        let ended = endedEntries(h)
        #expect(ended.count == 1 && ended[0].summary == "Sharing with Mom ended, as scheduled" && ended[0].client == "Veil")
        // Nothing else reaches the chat, and it doesn't happen twice.
        #expect(h.call("request_send", ["chat_id": .string(ID.mom), "text": "Hi"]).isError)
        #expect(h.call("list_attachments", ["chat_id": .string(ID.mom)]).isError)
        #expect(h.call("list_chats").json["chats"]?.array?.first { $0["chat_id"]?.string == ID.mom }?["allowed"] == .array([]))
        #expect(endedEntries(h).count == 1)
        #expect(h.sender.sent.isEmpty)
        // Signed like everything else.
        #expect(PermissionStore(url: h.permissionsURL, secrets: h.secrets).integrity == .ok)
    }

    @Test func theTimerPathLocksTooAndTellsTheApp() throws {
        let (h, clock) = try sharedForAnHour()
        var told: [String] = []
        h.gate.onSharingEnded = { told += $0 }
        #expect(h.gate.expireShares().isEmpty)
        clock.advance(3600)                          // exactly at the end time
        #expect(h.gate.expireShares() == [ID.mom])
        #expect(told == [ID.mom])
        expectLocked(h)
        #expect(endedEntries(h).count == 1)
    }

    @Test func expiryHoldsPerRequestEvenWhenTheLockCantBeWritten() throws {
        let (h, clock) = try sharedForAnHour()
        // Same files, a store whose writes now fail.
        let flaky = FlakySecretStore(copying: h.secrets)
        let store = PermissionStore(url: h.permissionsURL, secrets: flaky)
        let dir = h.dir
        let gate = Gate(permissions: store, log: AccessLog(url: nil), contacts: StaticContacts(DemoData.contacts), sender: RecordingSender(),
                        openStore: { try MessagesStore(databasePath: dir.appendingPathComponent("chat.db").path,
                                                       attachmentsRoot: dir.appendingPathComponent("Attachments")) })
        gate.clock = { clock.now }
        flaky.failSaves = true
        clock.advance(7200)
        let out = gate.call(tool: "read_chat", arguments: ["chat_id": .string(ID.mom)], client: "Test")
        #expect(out.isError)
        #expect(!JSON.array(out.content).encoded().contains("Call me"))
        #expect(gate.call(tool: "chat_activity", arguments: ["chat_id": .string(ID.mom)], client: "Test").isError)
        // The stored state still says shared (the write failed), but every policy check treats it as locked.
        #expect(store.state.chats[ID.mom]?.read == true)
        #expect(!store.state.access(ID.mom, now: clock.now).anyEnabled)
    }

    @Test func sharesThatEndedWhileVeilWasClosedAreLockedAtLaunch() throws {
        let h = try Harness()
        try h.gate.setShareExpiry(Date().addingTimeInterval(3600), for: ID.mom)
        // Saved (and signed) yesterday with a one-hour limit; Veil was closed since.
        try h.gate.permissions.update { $0.chats[ID.mom]?.expires = Date().addingTimeInterval(-86_400) }
        // Relaunch: a new store and gate on the same files, as the app does.
        let store = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        #expect(store.integrity == .ok)
        #expect(!store.state.access(ID.mom).anyEnabled)       // locked even before anything runs
        let dir = h.dir
        let log = AccessLog(url: nil)
        let gate = Gate(permissions: store, log: log, contacts: StaticContacts(DemoData.contacts), sender: RecordingSender(),
                        openStore: { try MessagesStore(databasePath: dir.appendingPathComponent("chat.db").path,
                                                       attachmentsRoot: dir.appendingPathComponent("Attachments")) })
        #expect(gate.expireShares() == [ID.mom])           // what the app runs at launch
        #expect(log.all.map(\.summary) == ["Sharing with Mom ended, as scheduled"])
        let reopened = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        #expect(reopened.integrity == .ok && reopened.state.chats[ID.mom]?.hasAnySwitch == false)
    }

    @Test func pingsStopTheMomentTheTimeIsUp() async throws {
        let p = try PingHarness(access: [ID.mom: ChatAccess(read: true)])
        // Run out, but not locked yet (between timer ticks).
        try p.h.gate.permissions.update { $0.chats[ID.mom]?.expires = Date().addingTimeInterval(-1) }
        try p.incoming(chatRow: 1)
        p.notifier.tick()
        await p.settle { !p.transport.requests.isEmpty }
        #expect(p.transport.requests.isEmpty)
    }

    @Test func changingSwitchesKeepsTheTimeLimit() throws {
        let (h, clock) = try sharedForAnHour()
        let end = try #require(h.gate.permissions.state.chats[ID.mom]?.expires)
        #expect(end == ShareDuration.hour.expiry(from: clock.now))
        clock.advance(600)
        try h.gate.setSwitches([\.draft: false, \.read: false], for: ID.mom)
        try h.gate.setHistory(.month, for: ID.mom)
        try h.gate.setFiltered(false, for: ID.mom)
        #expect(h.gate.permissions.state.chats[ID.mom]?.expires == end)
        // Changing it is explicit.
        let later = clock.now.addingTimeInterval(7200)
        try h.gate.setShareExpiry(later, for: ID.mom)
        #expect(h.gate.permissions.state.chats[ID.mom]?.expires == later.wholeSeconds)
        try h.gate.setShareExpiry(nil, for: ID.mom)
        #expect(h.gate.permissions.state.chats[ID.mom]?.expires == nil)
        // A locked chat can't have one.
        try h.gate.setShareExpiry(later, for: ID.therapist)
        #expect(h.gate.permissions.state.chats[ID.therapist]?.expires == nil)
    }

    @Test func aDurationPickedBeforeSharingStartsWithIt() throws {
        let h = try Harness(access: [:])
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        h.gate.clock = { clock.now }
        try h.gate.setSwitches([\.read: true], for: ID.therapist, startFor: .day)
        #expect(h.gate.permissions.state.chats[ID.therapist]?.expires == clock.now.addingTimeInterval(86_400))
        // Already shared: more switches don't restart the clock.
        clock.advance(60)
        try h.gate.setSwitches([\.draft: true], for: ID.therapist, startFor: .hour)
        #expect(h.gate.permissions.state.chats[ID.therapist]?.expires == clock.now.addingTimeInterval(86_400 - 60))
        try h.gate.setSwitches([\.read: true], for: ID.alex, startFor: .always)
        #expect(h.gate.permissions.state.chats[ID.alex]?.expires == nil)
    }

    @Test func endNowLocksLikeTheTimeRunningOut() throws {
        let (h, _) = try sharedForAnHour()
        try h.gate.endSharing(ID.mom)
        expectLocked(h)
        #expect(endedEntries(h).map(\.summary) == ["You stopped sharing Mom"])
    }

    @Test func turningSharingBackOnAfterItEndedStartsFresh() throws {
        let (h, clock) = try sharedForAnHour()
        clock.advance(4000)
        // The app's toggle on a share that ran out a moment ago (before any timer): the old switches don't come back.
        try h.gate.setSwitches([\.activity: true], for: ID.mom)
        let a = try #require(h.gate.permissions.state.chats[ID.mom])
        #expect(a.activity && !a.read && !a.send && !a.autoSend && a.expires == nil && a.sharedSince == clock.now.wholeSeconds)
        #expect(endedEntries(h).count == 1)
    }

    @Test func tonightMeansTheComingMidnight() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Europe/London")!
        let evening = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 21, minute: 30))!
        let midnight = cal.date(from: DateComponents(year: 2026, month: 11, day: 14))!
        #expect(ShareDuration.tonight.expiry(from: evening, calendar: cal) == midnight)
        #expect(ShareDuration.always.expiry(from: evening) == nil)
        #expect(ShareDuration.hour.expiry(from: evening) == evening.addingTimeInterval(3600))
        #expect(ShareDuration.week.expiry(from: evening) == evening.addingTimeInterval(7 * 86_400))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(ShareDuration.remaining(until: now.addingTimeInterval(45 * 60), now: now) == "45 more minutes")
        #expect(ShareDuration.remaining(until: now.addingTimeInterval(60), now: now) == "1 more minute")
        #expect(ShareDuration.remaining(until: now.addingTimeInterval(3 * 3600), now: now) == "3 more hours")
        #expect(ShareDuration.remaining(until: now.addingTimeInterval(5 * 86_400), now: now) == "5 more days")
        #expect(ShareDuration.remaining(until: now.addingTimeInterval(20), now: now) == "less than a minute")
        #expect(ShareDuration.remainingShort(until: now.addingTimeInterval(45 * 60), now: now) == "45 min left")
    }
}

@Suite("History and time limits: signed settings")
struct HistoryIntegrityTests {
    static let old = #"{"chats":{"x":{"attachments":false,"draft":false,"hidden":false,"read":true,"send":true,"waiting":false}},"generation":3,"paused":false,"reviewed":["x"]}"#

    @Test func olderFilesStillVerifyAndDefaultToAllAndAlways() throws {
        let decoded = try JSONDecoder().decode(PermissionState.self, from: Data(Self.old.utf8))
        let x = try #require(decoded.chats["x"])
        #expect(x.history == .all && x.expires == nil && x.sharedSince == nil)
        #expect(decoded.historyCutoff("x", now: Date()) == nil)
        #expect(decoded.access("x").read)
        // Byte-identical re-encoding (what the HMAC covers).
        let a = try JSONEncoder.sorted.encode(decoded)
        let sortedOld = try JSONEncoder.sorted.encode(try JSONDecoder().decode(JSON.self, from: Data(Self.old.utf8)))
        #expect(a == sortedOld)
        let json = String(decoding: a, as: UTF8.self)
        for k in ["history", "expires", "sharedSince"] { #expect(!json.contains(k)) }
    }

    @Test func aFileSignedBeforeTheseExistedStillLoads() throws {
        // A real signed file without the new fields (written the way an older version did) loads cleanly.
        let h = try Harness()
        try h.gate.permissions.update { s in for id in s.chats.keys { s.chats[id]?.sharedSince = nil } }
        let text = try String(contentsOf: h.permissionsURL, encoding: .utf8)
        for k in ["history", "expires", "sharedSince"] { #expect(!text.contains(k)) }
        let reloaded = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        #expect(reloaded.integrity == .ok)
        #expect(reloaded.state.chats[ID.mom]?.history == .all && reloaded.state.chats[ID.mom]?.expires == nil)
    }

    @Test func newFieldsRoundTripAndAreSigned() throws {
        let h = try Harness()
        try h.gate.setHistory(.sinceShared, for: ID.mom)
        let end = Date().addingTimeInterval(3600)
        try h.gate.setShareExpiry(end, for: ID.mom)
        let reloaded = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        #expect(reloaded.integrity == .ok)
        #expect(reloaded.state == h.gate.permissions.state)
        #expect(reloaded.state.chats[ID.mom]?.expires == end.wholeSeconds)

        // Pushing the end time back by hand fails closed.
        var text = try String(contentsOf: h.permissionsURL, encoding: .utf8)
        let stamp = String(Int64(end.wholeSeconds.timeIntervalSince1970))
        #expect(text.contains(stamp))
        text = text.replacingOccurrences(of: stamp, with: String(Int64(end.timeIntervalSince1970) + 86_400 * 365))
        try text.write(to: h.permissionsURL, atomically: true, encoding: .utf8)
        let edited = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        if case .tampered = edited.integrity {} else { Issue.record("hand-edited end time was accepted") }
        #expect(!edited.state.access(ID.mom).anyEnabled)
    }

    @Test func handWidenedHistoryFailsClosed() throws {
        let h = try Harness()
        try h.gate.setHistory(.day, for: ID.mom)
        var text = try String(contentsOf: h.permissionsURL, encoding: .utf8)
        #expect(text.contains("\"history\" : \"24h\""))
        text = text.replacingOccurrences(of: "\"history\" : \"24h\",", with: "")
        try text.write(to: h.permissionsURL, atomically: true, encoding: .utf8)
        let edited = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        if case .tampered = edited.integrity {} else { Issue.record("hand-widened history was accepted") }
        #expect(!edited.state.access(ID.mom).read)
    }

    @Test func unknownWindowValuesAreUnreadable() throws {
        let bad = Self.old.replacingOccurrences(of: #""read":true"#, with: #""history":"forever","read":true"#)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PermissionState.self, from: Data(bad.utf8)) }
    }
}
