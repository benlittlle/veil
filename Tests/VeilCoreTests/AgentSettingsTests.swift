import Foundation
import CryptoKit
import Testing
@testable import VeilCore

/// "Assistant can change settings": Off (the default), Ask me, Apply directly.
@Suite("Assistant settings changes")
struct AgentSettingsTests {
    static let settingsTools = ["get_settings", "get_chat_settings", "change_chat_settings", "change_app_settings", "check_settings_request"]

    func harness(_ mode: AgentSettingsMode, access: [String: ChatAccess] = Harness.defaultAccess) throws -> Harness {
        let h = try Harness(access: access)
        try h.gate.setAgentSettings(mode)
        return h
    }

    func listed(_ h: Harness) -> [String] {
        let s = h.server.makeSession()
        return s.handle(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])?["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
    }

    func instructions(_ h: Harness) -> String {
        let s = h.server.makeSession()
        return s.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["clientInfo": ["name": "Assistant"]]])?["result"]?["instructions"]?.string ?? ""
    }

    func change(_ h: Harness, _ chat: String, _ args: [String: JSON]) -> Harness.Out {
        var a = args; a["chat_id"] = .string(chat)
        return h.call("change_chat_settings", .object(a))
    }

    // MARK: Off

    @Test func offIsTheDefaultHidesTheToolsAndRefusesThem() throws {
        let h = try Harness()
        #expect(h.gate.permissions.state.agentSettings == .off)
        let names = listed(h)
        #expect(names.count == 10)
        #expect(Set(names).isDisjoint(with: Self.settingsTools))
        #expect(instructions(h).contains("You cannot change permissions"))
        for t in Self.settingsTools {
            let out = h.call(t, ["chat_id": .string(ID.therapist), "read": true, "request_id": "c-1"])
            #expect(out.isError)
            // Exactly the answer a tool that doesn't exist gets.
            #expect(out.text == "Unknown tool \(t).")
        }
        #expect(h.gate.permissions.state.access(ID.therapist) == .none)
    }

    @Test func askAndDirectListTheToolsAndSaySo() throws {
        let ask = try harness(.ask)
        #expect(Set(listed(ask)).isSuperset(of: Self.settingsTools) && listed(ask).count == 15)
        #expect(instructions(ask).contains("approves or declines"))
        #expect(!instructions(ask).contains("You cannot change permissions"))
        let direct = try harness(.direct)
        #expect(listed(direct).count == 15)
        #expect(instructions(direct).contains("right away"))
        #expect(direct.call("get_settings").json["settings_changes"]?.string == "direct")
        #expect(ask.call("get_settings").json["settings_changes"]?.string == "ask")
        // Back to Off: gone again.
        try direct.gate.setAgentSettings(.off)
        #expect(listed(direct).count == 10)
        #expect(direct.call("get_settings").text == "Unknown tool get_settings.")
    }

    // MARK: Ask me

    @Test func askCreatesAPendingRequestAndApprovalAppliesIt() throws {
        let h = try harness(.ask)
        var prompted: [SettingsRequest] = []
        h.gate.onSettingsRequested = { prompted.append($0) }
        let before = h.gate.permissions.state
        let out = change(h, ID.therapist, ["read": true])
        #expect(out.json["status"]?.string == "pending")
        let id = try #require(out.json["request_id"]?.string)
        #expect(h.gate.permissions.state == before)                 // nothing changed yet
        let r = try #require(prompted.first)
        #expect(r.phrases == ["turn on Read for Dr. Rivera"])
        #expect(h.call("check_settings_request", ["request_id": .string(id)]).json["status"]?.string == "pending")

        h.gate.approveSettings(id)
        #expect(h.gate.permissions.state.access(ID.therapist).read)
        #expect(h.call("check_settings_request", ["request_id": .string(id)]).json["status"]?.string == "approved")
        #expect(h.call("read_chat", ["chat_id": .string(ID.therapist)]).isError == false)
        let log = h.gate.log.all
        #expect(log.contains { $0.tool == "change_chat_settings" && $0.summary.contains("waiting for approval") })
        #expect(log.contains { $0.tool == "approve_settings" && $0.client == "You" && $0.outcome == .allowed && $0.summary.contains("Read on") })
    }

    @Test func thePromptIsPlainLanguage() throws {
        let h = try harness(.ask, access: [ID.mom: ChatAccess(send: true)])
        var prompted: [SettingsRequest] = []
        h.gate.onSettingsRequested = { prompted.append($0) }
        change(h, ID.mom, ["read": true, "auto_send": true])
        #expect(prompted.first?.phrases == ["turn on Read for Mom", "turn on Auto-send for Mom (5 per 10 min)"])
        #expect(prompted.first?.shortSummary == "Read on, Auto-send on (5 per 10 min)")
    }

    @Test func approvedOnlyOnce() throws {
        let h = try harness(.ask)
        let id = try #require(change(h, ID.therapist, ["read": true]).json["request_id"]?.string)
        h.gate.approveSettings(id)
        let gen = h.gate.permissions.state.generation
        h.gate.approveSettings(id)
        h.gate.declineSettings(id)
        #expect(h.gate.permissions.state.generation == gen)
        #expect(h.gate.log.all.filter { $0.tool == "approve_settings" }.count == 1)
        #expect(h.gate.settingsRequests.first { $0.id == id }?.status == .approved)
    }

    @Test func declineLeavesEverythingAsItWas() throws {
        let h = try harness(.ask)
        let before = h.gate.permissions.state
        let id = try #require(change(h, ID.mom, ["auto_send": true]).json["request_id"]?.string)
        h.gate.declineSettings(id)
        h.gate.approveSettings(id)          // too late: already declined
        #expect(h.gate.permissions.state == before)
        #expect(h.call("check_settings_request", ["request_id": .string(id)]).json["status"]?.string == "declined")
        #expect(h.gate.log.all.contains { $0.tool == "decline_settings" && $0.client == "You" })
    }

    @Test func requestsExpire() throws {
        let h = try harness(.ask)
        let id = try #require(change(h, ID.therapist, ["read": true]).json["request_id"]?.string)
        h.gate.expireSettingsRequests(now: Date().addingTimeInterval(h.gate.settingsRequestLifetime + 1))
        #expect(h.call("check_settings_request", ["request_id": .string(id)]).json["status"]?.string == "expired")
        h.gate.approveSettings(id)
        #expect(h.gate.permissions.state.access(ID.therapist).read == false)
        #expect(h.gate.log.all.contains { $0.tool == "expire_settings" })
        // An expired request no longer counts towards the limit.
        h.gate.settingsRequestLifetime = 0
        let late = try #require(change(h, ID.alex, ["send": true]).json["request_id"]?.string)
        h.gate.approveSettings(late)
        #expect(h.gate.permissions.state.access(ID.alex).send == false)
    }

    @Test func atMostThreeWaiting() throws {
        let h = try harness(.ask)
        for chat in [ID.therapist, ID.family, ID.unknown] { #expect(change(h, chat, ["read": true]).json["status"]?.string == "pending") }
        let fourth = h.call("change_app_settings", ["auto_send": false])
        #expect(fourth.isError && fourth.text.contains("3 settings changes waiting"))
        #expect(h.gate.settingsRequests.filter { $0.status == .pending }.count == 3)
    }

    @Test func approvalRechecksTheLiveSettings() throws {
        let h = try harness(.ask)
        // The chat was hidden in the meantime.
        let hidden = try #require(change(h, ID.therapist, ["read": true]).json["request_id"]?.string)
        try h.gate.setAccess(ChatAccess(hidden: true), for: ID.therapist)
        h.gate.approveSettings(hidden)
        #expect(h.gate.permissions.state.chats[ID.therapist]?.read == false)
        #expect(h.gate.settingsRequests.first { $0.id == hidden }?.status == .cancelled("that chat isn't available any more"))

        // Auto-send asked for while Send was on, approved after the user turned Send off.
        let auto = try #require(change(h, ID.mom, ["auto_send": true]).json["request_id"]?.string)
        try h.gate.setAccess(ChatAccess(read: true), for: ID.mom)
        h.gate.approveSettings(auto)
        #expect(h.gate.permissions.state.chats[ID.mom]?.autoSend == false)
        guard case .cancelled? = h.gate.settingsRequests.first(where: { $0.id == auto })?.status else { Issue.record("should be cancelled"); return }

        // Settings changes turned off: pending requests are cancelled and can't be approved.
        let off = try #require(change(h, ID.family, ["read": true]).json["request_id"]?.string)
        try h.gate.setAgentSettings(.off)
        h.gate.approveSettings(off)
        #expect(h.gate.permissions.state.access(ID.family).read == false)
        #expect(h.gate.settingsRequests.first { $0.id == off }?.status == .cancelled("the user turned off settings changes"))

        // Paused.
        try h.gate.setAgentSettings(.ask)
        let paused = try #require(change(h, ID.family, ["read": true]).json["request_id"]?.string)
        try h.gate.setPaused(true)
        h.gate.approveSettings(paused)
        try h.gate.setPaused(false)
        #expect(h.gate.permissions.state.access(ID.family).read == false)
    }

    @Test func approvalRefusedWhileLocked() throws {
        let h = try harness(.ask)
        let id = try #require(change(h, ID.family, ["read": true]).json["request_id"]?.string)
        try Data("{}".utf8).write(to: h.permissionsURL)
        h.gate.permissions.reload()
        guard case .tampered = h.gate.permissions.integrity else { Issue.record("should be locked"); return }
        h.gate.approveSettings(id)
        #expect(h.gate.permissions.state.access(ID.family).read == false)
        #expect(h.gate.log.all.contains { $0.tool == "approve_settings" && $0.outcome == .failed })
    }

    // MARK: Apply directly

    @Test func directAppliesLogsAndNotifies() throws {
        let h = try harness(.direct)
        var applied: [SettingsRequest] = []
        h.gate.onSettingsApplied = { applied.append($0) }
        var prompted = 0
        h.gate.onSettingsRequested = { _ in prompted += 1 }
        let out = change(h, ID.therapist, ["read": true, "waiting": true])
        #expect(out.json["status"]?.string == "applied")
        #expect(out.json["request_id"] == nil)
        #expect(h.gate.permissions.state.access(ID.therapist).read && h.gate.permissions.state.access(ID.therapist).waiting)
        #expect(prompted == 0)
        #expect(applied.count == 1 && applied.first?.shortSummary == "Read on, Notice who's waiting on")
        let e = try #require(h.gate.log.all.last)
        #expect(e.tool == "change_chat_settings" && e.outcome == .allowed && e.chatID == ID.therapist)
        #expect(e.summary == "Changed settings for Dr. Rivera: Read on, Notice who's waiting on")
        // A change the assistant made doesn't count as the user having looked at the chat.
        #expect(!h.gate.permissions.state.reviewed.contains(ID.therapist))
        // Asking for what's already set changes nothing.
        let gen = h.gate.permissions.state.generation
        #expect(change(h, ID.therapist, ["read": true]).json["status"]?.string == "unchanged")
        #expect(h.gate.permissions.state.generation == gen)
    }

    @Test func directChangesInABurstFallBackToAsking() throws {
        let h = try harness(.direct)
        let limit = Gate.directChangeLimit.count
        for i in 0..<limit {
            #expect(change(h, ID.therapist, ["read": i % 2 == 0]).json["status"]?.string == "applied")
        }
        let over = change(h, ID.therapist, ["waiting": true])
        #expect(over.json["status"]?.string == "pending")
        #expect(over.json["note"]?.string?.contains("need the user's approval") == true)
        #expect(!h.gate.permissions.state.access(ID.therapist).waiting)
        // App settings share the same limit.
        #expect(h.call("change_app_settings", ["assistant_name": "Helper"]).json["status"]?.string == "pending")
        // The window slides: old changes stop counting.
        #expect(h.gate.takeDirectChangeSlot(now: Date().addingTimeInterval(Gate.directChangeLimit.seconds + 1)))
    }

    @Test func directAppSettings() throws {
        let h = try harness(.direct)
        let out = h.call("change_app_settings", ["assistant_name": "Helper", "new_message_pings": true, "ping_when_i_reply": false,
                                                 "auto_send": false, "auto_send_limit": ["count": 3, "minutes": 30]])
        #expect(out.json["status"]?.string == "applied")
        let s = h.gate.permissions.state
        #expect(s.autoSendStopped && s.effectiveAutoSendLimit == AutoSendLimit(count: 3, minutes: 30))
        #expect(h.gate.preferences.assistantName == "Helper")
        #expect(h.gate.preferences.newMessagePings && !h.gate.preferences.pingWhenIReply)
        let got = h.call("get_settings").json
        #expect(got["assistant_name"]?.string == "Helper" && got["auto_send"]?.bool == false)
        #expect(got["auto_send_limit"]?["count"]?.int == 3)
    }

    @Test func pausingWorksButThenEverythingIsRefused() throws {
        let h = try harness(.direct)
        h.call("draft_reply", ["chat_id": .string(ID.mom), "text": "hi"])
        h.call("request_send", ["chat_id": .string(ID.mom), "text": "hi"])
        #expect(h.call("change_app_settings", ["paused": true]).json["status"]?.string == "applied")
        #expect(h.gate.permissions.state.paused)
        #expect(h.gate.sends.allSatisfy { $0.status != .waiting })
        for t in Self.settingsTools + ["list_chats"] {
            let out = h.call(t, ["paused": false, "chat_id": .string(ID.mom)])
            #expect(out.isError && out.text.contains("paused"))
        }
        #expect(h.gate.permissions.state.paused)
    }

    @Test func lockedStateRefusesAndHidesTheTools() throws {
        let h = try harness(.direct)
        try Data("{}".utf8).write(to: h.permissionsURL)
        h.gate.permissions.reload()
        #expect(listed(h).count == 10)
        for t in Self.settingsTools {
            let out = h.call(t, ["chat_id": .string(ID.mom), "read": true])
            #expect(out.isError && out.text.contains("locked"))
        }
    }

    // MARK: Never reachable

    @Test func noToolCanChangeTheMode() throws {
        for mode in [AgentSettingsMode.ask, .direct] {
            let h = try harness(mode)
            let attempts: [String: JSON] = ["settings_changes": "off", "agent_settings": "direct", "agentSettings": "direct",
                                            "mode": "direct", "assistant_can_change_settings": "direct"]
            for (k, v) in attempts {
                for t in Self.settingsTools + MCPServer.tools.compactMap({ $0["name"]?.string }) {
                    h.call(t, ["chat_id": .string(ID.mom), .init(k): v])
                    h.call(t, ["chat_id": .string(ID.mom), "filter": [.init(k): v]])
                }
            }
            #expect(h.gate.permissions.state.agentSettings == mode)
            #expect(h.gate.settingsRequests.isEmpty)
        }
        for t in MCPServer.settingsTools {
            let props = t["inputSchema"]?["properties"]?.objectKeys ?? []
            #expect(!props.contains { $0.contains("mode") || $0.contains("settings_changes") || $0.contains("agent") || $0.contains("hidden") })
        }
    }

    @Test func hiddenChatsAreUnreachable() throws {
        let h = try harness(.direct, access: [ID.therapist: ChatAccess(read: true, hidden: true)])
        for t in ["get_chat_settings", "change_chat_settings"] {
            let hidden = h.call(t, ["chat_id": .string(ID.therapist), "hidden": false, "read": true])
            let missing = h.call(t, ["chat_id": "chat999", "hidden": false, "read": true])
            #expect(hidden.isError && hidden.text == missing.text)
            #expect(!hidden.raw.contains("Rivera"))
        }
        // There's no way to unhide, even for a visible chat.
        let unhide = change(h, ID.mom, ["hidden": true])
        #expect(unhide.isError && unhide.text.contains("Unknown setting"))
        #expect(h.gate.permissions.state.chats[ID.therapist]?.hidden == true)
        #expect(h.gate.permissions.state.chats[ID.mom]?.hidden != true)
        #expect(!h.gate.log.all.contains { $0.chatID == ID.therapist })
    }

    @Test func webhookHTTPKeysAndLookAreUnreachable() throws {
        let h = try harness(.direct)
        let prefs = h.gate.preferences
        for k in ["webhook_url", "webhook", "webhook_header", "webhook_key", "http_token", "http", "local_web_address", "http_enabled",
                  "token", "key", "signing_key", "keychain", "accent", "appearance", "background", "open_at_login", "filter_profile"] {
            let out = h.call("change_app_settings", [.init(k): "https://evil.example.com"])
            #expect(out.isError && out.text.contains("Unknown setting"), "\(k)")
        }
        let got = Set(h.call("get_settings").json.objectKeys)
        #expect(got == ["settings_changes", "paused", "assistant_name", "new_message_pings", "ping_when_i_reply", "auto_send", "auto_send_limit", "note"])
        #expect(prefs.assistantName == "Assistant")
        #expect(!h.gate.log.all.map(\.summary).joined().contains("evil.example.com"))
    }

    // MARK: Validation

    @Test func autoSendWithoutSendIsRejected() throws {
        let h = try harness(.direct)
        let alex = change(h, ID.alex, ["auto_send": true])       // Send is off for Alex
        #expect(alex.isError && alex.text.contains("Auto-send needs Send"))
        let mom = change(h, ID.mom, ["send": false, "auto_send": true])
        #expect(mom.isError && mom.text.contains("Auto-send needs Send"))
        #expect(h.gate.permissions.state.chats[ID.mom]?.send == true)
        // Both together is fine, and turning Send off turns auto-send off with it (as in the app).
        #expect(change(h, ID.alex, ["send": true, "auto_send": true]).json["status"]?.string == "applied")
        #expect(h.gate.permissions.state.access(ID.alex).autoSend)
        let off = change(h, ID.alex, ["send": false])
        #expect(off.json["changes"]?.array?.compactMap(\.string) == ["Send with your OK off", "Auto-send off"])
        try h.gate.setAccess(ChatAccess(read: true, send: true), for: ID.alex)
        #expect(h.gate.permissions.state.access(ID.alex).autoSend == false)
    }

    @Test func allowingCodesAlwaysAsks() throws {
        let h = try harness(.direct)
        try h.gate.setFiltered(true, for: ID.alex)
        var prompted: [SettingsRequest] = []
        h.gate.onSettingsRequested = { prompted.append($0) }
        let codes = change(h, ID.alex, ["filter": ["categories": ["codes": "allow"]]])
        #expect(codes.json["status"]?.string == "pending")
        #expect(codes.json["note"]?.string?.contains("PINs") == true)
        #expect(h.gate.permissions.state.filterPolicy(for: ID.alex)?.action(.codes) == .mask)
        #expect(prompted.first?.caution != nil)
        // Turning the filter off would let codes through too.
        #expect(change(h, ID.alex, ["filter": ["on": false]]).json["status"]?.string == "pending")
        #expect(h.gate.permissions.state.access(ID.alex).filtered)
        // Other filter changes apply directly, starting from the default profile.
        #expect(change(h, ID.alex, ["filter": ["strictness": "strict", "photos": "withhold", "categories": ["politics": "allow"]]]).json["status"]?.string == "applied")
        let p = try #require(h.gate.permissions.state.filterPolicy(for: ID.alex))
        #expect(p.strictness == .strict && p.attachments == .withhold && p.action(.politics) == .allow && p.action(.codes) == .mask)
        // The user approves: now codes are allowed.
        h.gate.approveSettings(try #require(codes.json["request_id"]?.string))
        #expect(h.gate.permissions.state.filterPolicy(for: ID.alex)?.action(.codes) == .allow)
        // The tool says so.
        let desc = MCPServer.settingsTools.first { $0["name"]?.string == "change_chat_settings" }?["description"]?.string ?? ""
        #expect(desc.contains("PINs & verification codes") && desc.contains("always needs the user's approval"))
    }

    @Test func unknownKeysAndBadValuesAreRejected() throws {
        let h = try harness(.direct)
        let gen = h.gate.permissions.state.generation
        let bad: [[String: JSON]] = [
            ["reed": true], ["read": true, "reed": true], ["read": "yes"], ["read": 1], [:],
            ["filter": ["on": true, "foo": 1]], ["filter": "on"], ["filter": ["categories": ["cards": "allow"]]],
            ["filter": ["categories": ["swearing": "withhold"]]], ["filter": ["categories": ["nudity": "mask"]]],
            ["filter": ["strictness": "very"]], ["filter": ["photos": "maybe"]], ["auto_send": "on"],
            ["draft": true], ["attachments": true], ["filtered": true], ["autoSend": true],
        ]
        for args in bad {
            let out = change(h, ID.mom, args)
            #expect(out.isError, "\(args)")
            #expect(out.text.contains("Nothing was changed") || out.text.contains("must") || out.text.contains("Include"), "\(args): \(out.text)")
        }
        for args: [String: JSON] in [["pause": true], ["paused": "true"], ["assistant_name": ""], ["assistant_name": "You"],
                                     ["assistant_name": "Veil Security"], ["assistant_name": "line\nbreak"], ["assistant_name": "a\u{202E}b"],
                                     ["assistant_name": .string(String(repeating: "x", count: 31))],
                                     ["auto_send_limit": ["count": 0, "minutes": 10]], ["auto_send_limit": ["count": 5]],
                                     ["auto_send_limit": ["count": .number(2.5), "minutes": 10]], ["auto_send_limit": ["count": 5, "minutes": 10, "x": 1]]] {
            #expect(h.call("change_app_settings", .object(args)).isError, "\(args)")
        }
        #expect(h.gate.permissions.state.generation == gen)
        #expect(h.gate.preferences.assistantName == "Assistant")
        let msg = change(h, ID.mom, ["reed": true]).text
        #expect(msg.contains("reed") && msg.contains("Allowed:"))
    }

    // MARK: Same code paths as the app

    @Test func revokingPurgesDraftsAndWaitingSends() throws {
        let h = try harness(.direct)
        h.call("draft_reply", ["chat_id": .string(ID.mom), "text": "Draft"])
        h.call("request_send", ["chat_id": .string(ID.mom), "text": "Hi"])
        #expect(h.gate.drafts.count == 1 && h.gate.sends.first?.status == .waiting)
        #expect(change(h, ID.mom, ["drafts": false, "send": false]).json["status"]?.string == "applied")
        #expect(h.gate.drafts.isEmpty)
        #expect(h.gate.sends.first?.status == .cancelled("sending was turned off for this chat"))
        #expect(h.sender.sent.isEmpty)
    }

    @Test func settingsToolsNeverLeakContent() throws {
        let h = try harness(.direct)
        try h.gate.setFiltered(true, for: ID.alex)
        var outputs: [String] = []
        for id in [ID.mom, ID.alex, ID.therapist, ID.unknown, ID.climbing, ID.family] {
            outputs.append(h.call("get_chat_settings", ["chat_id": .string(id)]).raw)
            outputs.append(change(h, id, ["activity": true]).raw)
        }
        outputs.append(h.call("get_settings").raw)
        for o in outputs { #expect(!o.contains(secret)) }
        let log = h.gate.log.all.map { "\($0.summary) \($0.chatName ?? "")" }.joined(separator: "\n")
        #expect(!log.contains(secret))
        #expect(!log.contains("Call me when you can"))
        // get_chat_settings never shows the user's own review choices.
        try h.gate.setFilterAllowed(true, message: 20002, in: ID.alex)
        let alex = h.call("get_chat_settings", ["chat_id": .string(ID.alex)])
        #expect(!alex.raw.contains("20002"))
    }

    // MARK: Signed state

    @Test func oldSignedFilesStillVerifyAndReadAsOff() throws {
        // A permissions file written by a version that didn't have this setting, signed the way it signed.
        let h = try Harness()
        let (key, gen) = try #require(h.secrets.stored)
        let old: JSON = ["generation": .number(Double(gen + 1)), "paused": false, "reviewed": [.string(ID.mom)], "autoSendStopped": true,
                         "chats": [.init(ID.mom): ["attachments": false, "draft": false, "hidden": false, "read": true, "send": true, "waiting": false, "autoSend": true]]]
        let body = try JSONEncoder.sorted.encode(old)
        let mac = Data(HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: key))).base64EncodedString()
        try JSONEncoder.sorted.encode(["state": old, "mac": .string(mac)] as JSON).write(to: h.permissionsURL)
        let reopened = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        #expect(reopened.integrity == .ok)
        #expect(reopened.state.agentSettings == .off)
        #expect(reopened.state.access(ID.mom).read)
        // Off is never written, so re-encoding gives the bytes that were signed.
        #expect(!String(decoding: try JSONEncoder.sorted.encode(reopened.state), as: UTF8.self).contains("agentSettings"))
    }

    @Test func theModeIsSignedLikeEverythingElse() throws {
        let h = try harness(.ask)
        var text = try String(contentsOf: h.permissionsURL, encoding: .utf8)
        #expect(text.contains("\"agentSettings\" : \"ask\""))
        #expect(PermissionStore(url: h.permissionsURL, secrets: h.secrets).state.agentSettings == .ask)
        text = text.replacingOccurrences(of: "\"agentSettings\" : \"ask\"", with: "\"agentSettings\" : \"direct\"")
        try text.write(to: h.permissionsURL, atomically: true, encoding: .utf8)
        let edited = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        guard case .tampered = edited.integrity else { Issue.record("hand-edited mode was accepted"); return }
        #expect(edited.state.agentSettings == .off)
        // An unknown value fails closed too.
        let off = try harness(.off)
        var t2 = try String(contentsOf: off.permissionsURL, encoding: .utf8)
        t2 = t2.replacingOccurrences(of: "\"paused\" : false", with: "\"agentSettings\" : \"everything\",\n    \"paused\" : false")
        try t2.write(to: off.permissionsURL, atomically: true, encoding: .utf8)
        #expect(PermissionStore(url: off.permissionsURL, secrets: off.secrets).state.agentSettings == .off)
    }
}
