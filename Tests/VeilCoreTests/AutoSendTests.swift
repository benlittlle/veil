import Foundation
import Testing
@testable import VeilCore

final class FailingSender: MessageSender {
    func send(_ text: String, toChatGUID guid: String) throws {
        throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Messages is not signed in"])
    }
}

@Suite("Auto-send")
struct AutoSendTests {
    static let momAuto = ChatAccess(read: true, send: true, autoSend: true)

    func send(_ h: Harness, _ chat: String = ID.mom, _ text: String = "On my way!", extra: [String: JSON] = [:]) -> Harness.Out {
        var args: [String: JSON] = ["chat_id": .string(chat), "text": .string(text)]
        args.merge(extra) { a, _ in a }
        return h.call("request_send", .object(args))
    }

    @Test func offByDefaultKeepsTheApprovalPrompt() throws {
        let h = try Harness()
        var prompted = 0
        h.gate.onSendRequested = { _ in prompted += 1 }
        let out = send(h)
        #expect(out.json["status"]?.string == "waiting_for_approval")
        #expect(h.sender.sent.isEmpty)
        #expect(prompted == 1)
        #expect(h.gate.autoSends.all.isEmpty)
        #expect(ChatAccess().autoSend == false)
    }

    @Test func onSendsImmediatelyWithoutAPrompt() throws {
        let h = try Harness(access: [ID.mom: Self.momAuto])
        var prompted = 0
        h.gate.onSendRequested = { _ in prompted += 1 }
        var notified: [AutoSendRecord] = []
        h.gate.onAutoSend = { notified.append($0) }
        let out = send(h)
        #expect(out.json["status"]?.string == "sent")
        #expect(h.sender.sent.map(\.0) == ["On my way!"])
        #expect(h.sender.sent.first?.1 == "iMessage;-;+15550100001")
        #expect(prompted == 0)
        #expect(notified.count == 1)
        let rec = try #require(h.gate.autoSends.all.first)
        #expect(rec.chatID == ID.mom && rec.text == "On my way!" && rec.outcome == .sent && rec.client == "Test")
        // check_send_status agrees
        let id = try #require(out.json["request_id"]?.string)
        #expect(h.call("check_send_status", ["request_id": .string(id)]).json["status"]?.string == "sent")
        #expect(h.gate.log.all.contains { $0.tool == "request_send" && $0.summary.contains("Auto-sent") })
        // History is on disk for the user, with the text.
        let file = try String(contentsOf: h.dir.appendingPathComponent("auto-sent.jsonl"), encoding: .utf8)
        #expect(file.contains("On my way!"))
    }

    @Test func needsTheSendPermissionAndLockedChatsStayLocked() throws {
        let h = try Harness(access: [
            ID.mom: ChatAccess(read: true, autoSend: true),                 // auto without send
            ID.therapist: ChatAccess(autoSend: true),                       // locked
            ID.family: ChatAccess(send: true, hidden: true, autoSend: true), // hidden
        ])
        for chat in [ID.mom, ID.therapist, ID.family, ID.unknown] {
            #expect(send(h, chat).isError)
        }
        #expect(h.sender.sent.isEmpty)
        #expect(h.gate.autoSends.all.isEmpty)
        #expect(h.gate.permissions.state.access(ID.mom).autoSend == false)
    }

    @Test func rateLimitFallsBackToApproval() throws {
        let h = try Harness(access: [ID.mom: Self.momAuto])
        try h.gate.setAutoSendLimit(AutoSendLimit(count: 2, minutes: 10))
        var prompted = 0
        h.gate.onSendRequested = { _ in prompted += 1 }
        #expect(send(h, ID.mom, "one").json["status"]?.string == "sent")
        #expect(send(h, ID.mom, "two").json["status"]?.string == "sent")
        let third = send(h, ID.mom, "three")
        #expect(third.json["status"]?.string == "waiting_for_approval")
        #expect(third.json["note"]?.string?.contains("limit") == true)
        #expect(h.sender.sent.map(\.0) == ["one", "two"])
        #expect(prompted == 1)
        // Clearing the visible history doesn't reset the limit.
        h.gate.autoSends.clear()
        #expect(send(h, ID.mom, "four").json["status"]?.string == "waiting_for_approval")
    }

    @Test func defaultLimitIsFivePerTenMinutes() throws {
        let h = try Harness(access: [ID.mom: Self.momAuto])
        let statuses = (1...6).map { send(h, ID.mom, "msg \($0)").json["status"]?.string }
        #expect(statuses.filter { $0 == "sent" }.count == 5)
        #expect(statuses.last == "waiting_for_approval")
    }

    @Test func limitSurvivesARestart() throws {
        let h = try Harness(access: [ID.mom: Self.momAuto])
        try h.gate.setAutoSendLimit(AutoSendLimit(count: 1, minutes: 10))
        #expect(send(h).json["status"]?.string == "sent")
        let reopened = Gate(permissions: h.gate.permissions, log: AccessLog(url: nil), contacts: h.gate.contacts, sender: h.sender,
                            autoSends: AutoSendHistory(url: h.dir.appendingPathComponent("auto-sent.jsonl")),
                            openStore: { try h.gate.messagesStore() })
        let out = Harness.Out(result: reopened.call(tool: "request_send", arguments: ["chat_id": .string(ID.mom), "text": "again"], client: "Test"))
        #expect(out.json["status"]?.string == "waiting_for_approval")
        #expect(h.sender.sent.count == 1)
    }

    @Test func killSwitchStopsEveryChatAndKeepsChoices() throws {
        let h = try Harness(access: [ID.mom: Self.momAuto, ID.alex: ChatAccess(send: true, autoSend: true)])
        try h.gate.setAutoSendStopped(true)
        #expect(send(h, ID.mom).json["status"]?.string == "waiting_for_approval")
        #expect(send(h, ID.alex).json["status"]?.string == "waiting_for_approval")
        #expect(h.sender.sent.isEmpty)
        #expect(h.gate.permissions.state.chats[ID.mom]?.autoSend == true)
        #expect(!h.call("list_chats").raw.contains("auto_send"))
        try h.gate.setAutoSendStopped(false)
        #expect(send(h, ID.mom).json["status"]?.string == "sent")
        #expect(h.call("list_chats").raw.contains("auto_send"))
    }

    @Test func pauseBlocksAutoSend() throws {
        let h = try Harness(access: [ID.mom: Self.momAuto])
        try h.gate.setPaused(true)
        #expect(send(h).isError)
        #expect(h.sender.sent.isEmpty)
    }

    @Test func anythingButPlainTextNeedsApproval() throws {
        let h = try Harness(access: [ID.mom: Self.momAuto])
        let out = send(h, extra: ["attachment_id": 12])
        #expect(out.json["status"]?.string == "waiting_for_approval")
        #expect(out.json["note"]?.string?.contains("plain text") == true)
        #expect(h.sender.sent.isEmpty)
        // The usual text checks still apply.
        #expect(send(h, ID.mom, "hi\u{202E}there").isError)
        #expect(send(h, ID.mom, String(repeating: "a", count: 2001)).isError)
        #expect(h.sender.sent.isEmpty)
    }

    @Test func failedSendIsReportedAndRecorded() throws {
        let h = try Harness(access: [ID.mom: Self.momAuto], sender: FailingSender())
        let out = send(h)
        #expect(out.json["status"]?.string?.hasPrefix("failed") == true)
        #expect(!out.raw.contains("not signed in"))                // internal detail stays with the user
        let rec = try #require(h.gate.autoSends.all.first)
        #expect(rec.outcome == .failed && rec.detail == "Messages is not signed in")
    }

    @Test func turningSendOffStopsAutoSend() throws {
        let h = try Harness(access: [ID.mom: Self.momAuto])
        try h.gate.setAccess(ChatAccess(read: true, send: false, autoSend: true), for: ID.mom)
        #expect(send(h).isError)
        #expect(h.sender.sent.isEmpty)
    }

    @Test func mcpCannotToggleAutoSend() throws {
        let names = MCPServer.tools.compactMap { $0["name"]?.string }
        #expect(!names.contains { $0.contains("auto") || $0.contains("limit") || $0.contains("kill") })
        let h = try Harness()
        for t in ["set_auto_send", "auto_send", "enable_auto_send", "set_auto_send_limit", "approve_send"] {
            #expect(h.call(t, ["chat_id": .string(ID.mom), "enabled": true]).isError)
        }
        #expect(h.gate.permissions.state.chats[ID.mom]?.autoSend == false)
        #expect(send(h).json["status"]?.string == "waiting_for_approval")
    }

    @Test func olderPermissionFilesStillVerify() throws {
        // Default values of the new settings are left out of the signed encoding, so files
        // signed before this feature produce the same bytes and pass the HMAC check.
        var s = PermissionState()
        s.chats[ID.mom] = ChatAccess(read: true, send: true)
        let json = String(decoding: try JSONEncoder.sorted.encode(s), as: UTF8.self)
        #expect(!json.contains("autoSend"))
        let old = #"{"chats":{"x":{"attachments":false,"draft":false,"hidden":false,"read":true,"send":true,"waiting":false}},"generation":3,"paused":false,"reviewed":["x"]}"#
        let decoded = try JSONDecoder().decode(PermissionState.self, from: Data(old.utf8))
        #expect(decoded.chats["x"]?.autoSend == false && decoded.autoSendStopped == false && decoded.autoSendLimit == nil)
        let reencoded = try JSONEncoder().encode(decoded)
        let again = try JSONDecoder().decode(PermissionState.self, from: reencoded)
        #expect(again == decoded)
    }

    @Test func autoSendSettingsAreSignedLikeEverythingElse() throws {
        let h = try Harness(access: [ID.mom: ChatAccess(read: true, send: true)])
        // Flip autoSend in the file by hand: the store must refuse it.
        var text = try String(contentsOf: h.permissionsURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"send\" : true", with: "\"autoSend\" : true,\n      \"send\" : true")
        try text.write(to: h.permissionsURL, atomically: true, encoding: .utf8)
        let reopened = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        if case .tampered = reopened.integrity {} else { Issue.record("hand-edited auto-send was accepted") }
        #expect(reopened.state.access(ID.mom).autoSend == false)
    }
}
