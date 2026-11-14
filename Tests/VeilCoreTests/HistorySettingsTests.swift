import Foundation
import Testing
@testable import VeilCore

/// The settings tools and the two new per-chat settings: `history` and `share_for`.
/// Sharing more (a longer window, a later or no end) always asks; sharing less applies directly.
@Suite("Assistant settings: history and time limits")
struct HistorySettingsTests {
    func harness(_ mode: AgentSettingsMode) throws -> (Harness, TestClock) {
        let h = try Harness()
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        h.gate.clock = { clock.now }
        try h.gate.setAgentSettings(mode)
        return (h, clock)
    }

    func change(_ h: Harness, _ args: [String: JSON], chat: String = ID.mom) -> Harness.Out {
        var a = args; a["chat_id"] = .string(chat)
        return h.call("change_chat_settings", .object(a))
    }
    func mom(_ h: Harness) -> ChatAccess { h.gate.permissions.state.chats[ID.mom] ?? .none }

    @Test func getChatSettingsShowsHistoryAndTheEndTime() throws {
        let (h, clock) = try harness(.ask)
        var s = h.call("get_chat_settings", ["chat_id": .string(ID.mom)]).json
        #expect(s["history"]?.string == "all" && s["shared_until"] == .null)
        try h.gate.setHistory(.week, for: ID.mom)
        try h.gate.setShareExpiry(clock.now.addingTimeInterval(3600), for: ID.mom)
        s = h.call("get_chat_settings", ["chat_id": .string(ID.mom)]).json
        #expect(s["history"]?.string == "7d")
        #expect(s["shared_until"]?.string.flatMap { ISO8601DateFormatter().date(from: $0) } == clock.now.addingTimeInterval(3600))
    }

    @Test func narrowingHistoryAppliesDirectly() throws {
        let (h, _) = try harness(.direct)
        for (w, expect) in [("30d", HistoryWindow.month), ("7d", .week), ("24h", .day)] {
            let out = change(h, ["history": .string(w)])
            #expect(out.json["status"]?.string == "applied", "\(w)")
            #expect(mom(h).history == expect)
        }
        #expect(h.gate.log.all.last?.summary == "Changed settings for Mom: History: Last 24 hours")
    }

    @Test func wideningHistoryAlwaysAsksEvenInApplyDirectly() throws {
        let (h, clock) = try harness(.direct)
        try h.gate.setHistory(.day, for: ID.mom)
        var prompted: [SettingsRequest] = []
        h.gate.onSettingsRequested = { prompted.append($0) }
        for w in ["7d", "30d", "all"] {
            let out = change(h, ["history": .string(w)])
            #expect(out.json["status"]?.string == "pending", "\(w)")
            #expect(out.json["note"]?.string?.contains("Sharing more history, or sharing for longer, always needs the user's approval") == true)
            #expect(mom(h).history == .day)
        }
        #expect(prompted.first?.phrases == ["set the history it can see to “Last 7 days” for Mom"])
        #expect(prompted.first?.caution != nil)
        // The user allows one: it applies then.
        h.gate.approveSettings(try #require(prompted.last?.id))
        #expect(mom(h).history == .all)
        // "Since shared" compares by its actual start: shared 2 days ago, so 24 hours is less and 30 days is more.
        try h.gate.setHistory(.sinceShared, for: ID.mom)
        try h.gate.permissions.update { $0.chats[ID.mom]?.sharedSince = clock.now.addingTimeInterval(-2 * 86_400) }
        #expect(change(h, ["history": "24h"]).json["status"]?.string == "applied")
        try h.gate.setHistory(.sinceShared, for: ID.mom)
        #expect(change(h, ["history": "30d"]).json["status"]?.string == "pending")
    }

    @Test func shorteningOrAddingAnEndAppliesDirectly() throws {
        let (h, clock) = try harness(.direct)
        // No time limit → 7 days: sharing less, applies right away.
        #expect(change(h, ["share_for": "7d"]).json["status"]?.string == "applied")
        #expect(mom(h).expires == clock.now.addingTimeInterval(7 * 86_400))
        // 7 days → 1 hour: earlier, applies.
        let out = change(h, ["share_for": "1h"])
        #expect(out.json["status"]?.string == "applied")
        #expect(out.json["changes"] == ["Shared for 1 hour"])
        #expect(mom(h).expires == clock.now.addingTimeInterval(3600))
    }

    @Test func extendingOrRemovingTheEndAlwaysAsks() throws {
        let (h, clock) = try harness(.direct)
        try h.gate.setShareExpiry(clock.now.addingTimeInterval(3600), for: ID.mom)
        let end = mom(h).expires
        var ids: [String] = []
        for d in ["24h", "7d", "always"] {
            let out = change(h, ["share_for": .string(d)])
            #expect(out.json["status"]?.string == "pending", "\(d)")
            ids.append(try #require(out.json["request_id"]?.string))
            #expect(mom(h).expires == end)
        }
        // Approving "always" removes the limit, counted from when the user approves.
        clock.advance(600)
        h.gate.approveSettings(ids[2])
        #expect(mom(h).expires == nil)
        // In Ask me, everything asks anyway.
        let (ask, _) = try harness(.ask)
        #expect(change(ask, ["share_for": "1h"]).json["status"]?.string == "pending")
    }

    @Test func approvedDurationsCountFromApproval() throws {
        let (h, clock) = try harness(.ask)
        let id = try #require(change(h, ["share_for": "1h", "history": "7d"]).json["request_id"]?.string)
        clock.advance(300)
        h.gate.approveSettings(id)
        #expect(mom(h).expires == clock.now.addingTimeInterval(3600))
        #expect(mom(h).history == .week)
    }

    @Test func aWideningAndANarrowingTogetherAsk() throws {
        let (h, clock) = try harness(.direct)
        try h.gate.setHistory(.day, for: ID.mom)
        try h.gate.setShareExpiry(clock.now.addingTimeInterval(86_400), for: ID.mom)
        #expect(change(h, ["history": "all", "share_for": "1h"]).json["status"]?.string == "pending")
        #expect(change(h, ["history": "24h", "share_for": "7d"]).json["status"]?.string == "pending")
        #expect(change(h, ["read": false, "share_for": "1h"]).json["status"]?.string == "applied")
    }

    @Test func valuesAreValidatedStrictly() throws {
        let (h, _) = try harness(.direct)
        let before = h.gate.permissions.state
        for (k, v) in [("history", JSON.string("forever")), ("history", .bool(true)), ("history", "7 days"),
                       ("share_for", "2h"), ("share_for", .number(3600)), ("share_for", "Always")] {
            let out = change(h, [k: v])
            #expect(out.isError, "\(k)=\(v.encoded())")
            #expect(out.text.contains("\(k) must be one of"))
        }
        // An end time needs something shared.
        let locked = change(h, ["share_for": "1h"], chat: ID.therapist)
        #expect(locked.isError && locked.text.contains("share_for needs something shared"))
        #expect(change(h, ["read": false, "waiting": false, "drafts": false, "send": false, "photos": false, "share_for": "1h"]).isError)
        #expect(h.gate.permissions.state == before)
        // Turning a chat on with a limit in one go is fine.
        #expect(change(h, ["read": true, "share_for": "tonight"], chat: ID.therapist).json["status"]?.string == "applied")
        #expect(h.gate.permissions.state.chats[ID.therapist]?.expires != nil)
        // Already that way: unchanged.
        #expect(change(h, ["history": "all"]).json["status"]?.string == "unchanged")
        #expect(change(h, ["share_for": "always"]).json["status"]?.string == "unchanged")
    }

    @Test func hiddenChatsStayOutOfReach() throws {
        let h = try Harness(access: [ID.therapist: ChatAccess(read: true, hidden: true)])
        try h.gate.setAgentSettings(.direct)
        let out = change(h, ["history": "all"], chat: ID.therapist)
        #expect(out.isError && out.text.contains("No chat with that chat_id"))
    }

    @Test func toolDescriptionsExplainTheRule() throws {
        let tool = try #require(MCPServer.settingsTools.first { $0["name"]?.string == "change_chat_settings" })
        let props = tool["inputSchema"]?["properties"]
        #expect(props?["history"]?["enum"] == ["all", "24h", "7d", "30d", "since_shared"])
        #expect(props?["share_for"]?["enum"] == ["always", "1h", "tonight", "24h", "7d"])
        #expect(tool["description"]?.string?.contains("a share_for that ends later than now or removes the time limit") == true)
    }
}
