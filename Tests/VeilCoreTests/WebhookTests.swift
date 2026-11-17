import Foundation
import Testing
@testable import VeilCore

/// Records requests instead of using the network. `responses` are used in order; the last repeats.
/// While `holding`, answers wait until `release()`, so a test can act between a request and its answer.
final class FakeTransport: WebhookTransport {
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    private var held: [() -> Void] = []
    var responses: [(Int?, Error?)] = [(200, nil)]
    var holding = false
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return _requests }

    func post(_ request: URLRequest, completion: @escaping (Int?, Error?) -> Void) {
        lock.lock()
        let i = _requests.count
        _requests.append(request)
        let r = responses[min(i, responses.count - 1)]
        let answer = { completion(r.0, r.1) }
        if holding { held.append(answer); lock.unlock(); return }
        lock.unlock()
        DispatchQueue.global().async(execute: answer)
    }

    /// Delivers the answers held so far, and answers straight away from now on.
    func release() {
        lock.lock(); let waiting = held; held = []; holding = false; lock.unlock()
        for a in waiting { DispatchQueue.global().async(execute: a) }
    }
}

/// A notifier on the fixture database, plus a writable connection to add "incoming" messages.
final class PingHarness {
    let h: Harness
    let transport = FakeTransport()
    let notifier: WebhookNotifier
    let db: SQLiteDB
    let key = "sk-test-SUPERSECRETKEY"
    private var nextID: Int64 = 10_000

    init(access: [String: ChatAccess] = Harness.defaultAccess, retryDelays: [TimeInterval] = [0.01, 0.01, 0.01]) throws {
        h = try Harness(access: access)
        let path = h.dir.appendingPathComponent("chat.db").path
        let atts = h.dir.appendingPathComponent("Attachments")
        db = try SQLiteDB(path: path, readOnly: false)
        notifier = WebhookNotifier(permissions: h.gate.permissions,
                                   openStore: { try MessagesStore(databasePath: path, attachmentsRoot: atts) },
                                   log: WebhookLog(url: h.dir.appendingPathComponent("webhook-log.jsonl")),
                                   transport: transport, interval: 60, retryDelays: retryDelays)
        notifier.configure(WebhookConfig(url: URL(string: "https://hooks.example.com/ping")!, headerName: "Authorization", key: key))
        notifier.tick()   // sets the baseline; nothing from the fixture is announced
    }

    /// Chat row ids from the fixture: 1/2 Mom, 3 Alex, 4 therapist, 5 unknown, 6 climbing, 7 family.
    @discardableResult
    func incoming(chatRow: Int64, text: String = "SECRET new text", fromMe: Bool = false, reaction: Int64 = 0,
                  date: Date = Date()) throws -> Int64 {
        nextID += 1
        try db.query("INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, associated_message_type, item_type) VALUES (?,?,?,?,?,?,?,0)",
                     [.int(nextID), .text("NEW-\(nextID)"), .text(text), .int(1), .int(appleTimestamp(date)), .int(fromMe ? 1 : 0), .int(reaction)])
        try db.query("INSERT INTO chat_message_join VALUES (?, ?, ?)", [.int(chatRow), .int(nextID), .int(appleTimestamp(date))])
        return nextID
    }

    var bodies: [[String: Any]] {
        transport.requests.compactMap { $0.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } }
    }

    /// Waits for async deliveries and retries to land, then a moment longer to catch anything extra.
    /// The limit is generous so a busy machine can't fail a test; a passing test never waits for it.
    func settle(until done: () -> Bool) async {
        let deadline = Date().addingTimeInterval(20)
        while !done(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    /// For checks that nothing is sent. A ping is handed to the transport inside `tick` itself, so
    /// this only gives a stray retry a chance to show up.
    func settle() async { try? await Task.sleep(nanoseconds: 200_000_000) }
}

@Suite("New-message pings")
struct WebhookTests {
    @Test func pingsOnlyForReadableChatsAndCarriesNoContent() async throws {
        let p = try PingHarness()
        let momMsg = try p.incoming(chatRow: 1, text: "Dinner at 7?")
        try p.incoming(chatRow: 7)                       // Family surprise: locked
        try p.incoming(chatRow: 4)                       // Therapist: locked
        try p.incoming(chatRow: 5)                       // Unknown number: locked by default
        try p.incoming(chatRow: 3, fromMe: true)         // the user's own message in an open chat
        try p.incoming(chatRow: 6, reaction: 2000)       // Tapback in an open chat
        p.notifier.tick()
        await p.settle { p.transport.requests.count >= 1 }

        #expect(p.transport.requests.count == 1)
        let body = try #require(p.bodies.first)
        #expect(Set(body.keys) == ["event", "chat_id", "message_id", "received_at", "direction"])
        #expect(body["direction"] as? String == "incoming")
        #expect(body["event"] as? String == "new_message")
        #expect(body["chat_id"] as? String == ID.mom)
        #expect((body["message_id"] as? NSNumber)?.int64Value == momMsg)
        #expect(ISO8601DateFormatter().date(from: body["received_at"] as? String ?? "") != nil)

        let raw = p.transport.requests.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }.joined()
        for leak in [secret, "Dinner", "Mom", ID.family, ID.therapist, ID.unknown] { #expect(!raw.contains(leak)) }

        let req = try #require(p.transport.requests.first)
        #expect(req.httpMethod == "POST")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(p.key)")
        #expect(req.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test func customHeaderSendsBareKey() async throws {
        let p = try PingHarness()
        p.notifier.configure(WebhookConfig(url: URL(string: "https://hooks.example.com/ping")!, headerName: "X-Routine-Key", key: p.key))
        try p.incoming(chatRow: 1)
        p.notifier.tick()
        await p.settle { !p.transport.requests.isEmpty }
        #expect(p.transport.requests.first?.value(forHTTPHeaderField: "X-Routine-Key") == p.key)
        #expect(p.transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func backlogIsNeverAnnounced() async throws {
        let p = try PingHarness()
        p.notifier.tick()
        await p.settle()
        #expect(p.transport.requests.isEmpty)
    }

    @Test func burstsCoalesceToOnePingPerMinuteWithNewestID() async throws {
        let p = try PingHarness()
        let t0 = Date()
        try p.incoming(chatRow: 1)
        p.notifier.tick(now: t0)
        await p.settle { p.transport.requests.count >= 1 }
        try p.incoming(chatRow: 1)
        try p.incoming(chatRow: 2)                       // same conversation, SMS row
        let newest = try p.incoming(chatRow: 1)
        p.notifier.tick(now: t0.addingTimeInterval(5))
        p.notifier.tick(now: t0.addingTimeInterval(30))
        await p.settle()
        #expect(p.transport.requests.count == 1)
        p.notifier.tick(now: t0.addingTimeInterval(61))
        await p.settle { p.transport.requests.count >= 2 }
        #expect(p.transport.requests.count == 2)
        #expect((p.bodies.last?["message_id"] as? NSNumber)?.int64Value == newest)
    }

    @Test func lockingAChatCancelsItsPendingPing() async throws {
        let p = try PingHarness()
        let t0 = Date()
        try p.incoming(chatRow: 1)
        p.notifier.tick(now: t0)
        await p.settle { p.transport.requests.count >= 1 }
        try p.incoming(chatRow: 1)
        p.notifier.tick(now: t0.addingTimeInterval(10))   // queued for the end of the quiet minute
        try p.h.gate.setAccess(ChatAccess(waiting: true), for: ID.mom)
        p.notifier.tick(now: t0.addingTimeInterval(61))
        await p.settle()
        #expect(p.transport.requests.count == 1)
        #expect(p.notifier.log.all.contains { $0.outcome == .dropped && $0.chatID == ID.mom })
    }

    @Test func pausedHiddenAndWaitingOnlyChatsNeverPing() async throws {
        let p = try PingHarness(access: [
            ID.mom: ChatAccess(read: true, hidden: true),
            ID.alex: ChatAccess(waiting: true, draft: true, send: true, attachments: true),   // everything but read
            ID.climbing: ChatAccess(read: true),
        ])
        try p.incoming(chatRow: 1); try p.incoming(chatRow: 3)
        try p.h.gate.setPaused(true)
        try p.incoming(chatRow: 6)
        p.notifier.tick()
        await p.settle()
        #expect(p.transport.requests.isEmpty)
    }

    @Test func tamperedPermissionsMeanNoPings() async throws {
        let p = try PingHarness()
        try Data("{}".utf8).write(to: p.h.permissionsURL)
        // A fresh store on the edited file fails closed; the notifier must follow it.
        let store = PermissionStore(url: p.h.permissionsURL, secrets: p.h.secrets)
        let path = p.h.dir.appendingPathComponent("chat.db").path
        let n = WebhookNotifier(permissions: store, openStore: { try MessagesStore(databasePath: path, attachmentsRoot: p.h.dir) },
                                log: WebhookLog(url: nil), transport: p.transport)
        n.configure(WebhookConfig(url: URL(string: "https://hooks.example.com")!, headerName: "Authorization", key: "k"))
        n.tick()
        try p.incoming(chatRow: 1)
        n.tick()
        await p.settle()
        #expect(p.transport.requests.isEmpty)
    }

    @Test func oldMessagesFromASyncAreIgnored() async throws {
        let p = try PingHarness()
        try p.incoming(chatRow: 1, date: Date().addingTimeInterval(-3 * 86400))
        p.notifier.tick()
        await p.settle()
        #expect(p.transport.requests.isEmpty)
    }

    @Test func turningOffForgetsPendingAndRestartsFromNow() async throws {
        let p = try PingHarness()
        try p.incoming(chatRow: 1)
        p.notifier.configure(nil)
        p.notifier.tick()
        p.notifier.configure(WebhookConfig(url: URL(string: "https://hooks.example.com")!, headerName: "Authorization", key: "k"))
        p.notifier.tick()   // new baseline: the message that arrived while off is not announced
        await p.settle()
        #expect(p.transport.requests.isEmpty)
    }

    @Test func retriesWithBackoffThenSucceeds() async throws {
        let p = try PingHarness()
        p.transport.responses = [(nil, URLError(.notConnectedToInternet)), (503, nil), (200, nil)]
        try p.incoming(chatRow: 1)
        p.notifier.tick()
        await p.settle { p.notifier.log.all.last?.outcome == .sent }
        #expect(p.transport.requests.count == 3)
        #expect(p.notifier.log.all.map(\.outcome) == [.retrying, .retrying, .sent])
        #expect(p.notifier.log.all.first?.detail.contains("No internet connection") == true)
    }

    @Test func dropsAfterAFewTries() async throws {
        let p = try PingHarness()
        p.transport.responses = [(500, nil)]
        try p.incoming(chatRow: 1)
        p.notifier.tick()
        await p.settle { p.notifier.log.all.last?.outcome == .dropped }
        #expect(p.transport.requests.count == 4)
        #expect(p.notifier.log.all.last?.outcome == .dropped)
    }

    @Test func rejectedKeyIsNotRetried() async throws {
        let p = try PingHarness()
        p.transport.responses = [(401, nil)]
        try p.incoming(chatRow: 1)
        p.notifier.tick()
        await p.settle { !p.notifier.log.all.isEmpty }
        #expect(p.transport.requests.count == 1)
        #expect(p.notifier.log.all.last?.outcome == .failed)
    }

    @Test func testPingWorksAndKeyNeverReachesTheLog() async throws {
        let p = try PingHarness()
        p.transport.responses = [(nil, URLError(.timedOut)), (200, nil)]
        let cfg = WebhookConfig(url: URL(string: "https://hooks.example.com/ping?x=1")!, headerName: "Authorization", key: p.key)
        var results: [WebhookLogEntry] = []
        let lock = NSLock()
        for _ in 0..<2 { p.notifier.sendTest(cfg) { e in lock.lock(); results.append(e); lock.unlock() } }
        await p.settle { lock.lock(); defer { lock.unlock() }; return results.count == 2 }
        #expect(Set(results.map(\.outcome)) == [.failed, .sent])
        #expect(p.bodies.allSatisfy { $0["event"] as? String == "test" && $0["chat_id"] == nil })

        let file = try String(contentsOf: p.h.dir.appendingPathComponent("webhook-log.jsonl"), encoding: .utf8)
        #expect(!file.isEmpty)
        for leak in [p.key, "SUPERSECRETKEY", "hooks.example.com"] { #expect(!file.contains(leak)) }
        #expect(!p.h.gate.log.all.map { "\($0)" }.joined().contains(p.key))
    }

    @Test func mcpCannotSeeOrChangePings() throws {
        let names = MCPServer.tools.compactMap { $0["name"]?.string }
        #expect(!names.contains { $0.contains("webhook") || $0.contains("ping") || $0.contains("notif") })
        let h = try Harness()
        for t in ["set_webhook", "configure_webhook", "get_webhook", "webhook_config"] {
            #expect(h.call(t, ["url": "https://evil.example.com"]).isError)
        }
    }

    @Test func settingsValidation() {
        #expect(WebhookConfig.problem(url: "https://hooks.example.com/x", headerName: "Authorization") == nil)
        #expect(WebhookConfig.problem(url: "http://127.0.0.1:8080/x", headerName: "X-Key") == nil)
        #expect(WebhookConfig.problem(url: "http://hooks.example.com/x", headerName: "Authorization") != nil)
        #expect(WebhookConfig.problem(url: "https://user:pw@hooks.example.com", headerName: "Authorization") != nil)
        #expect(WebhookConfig.problem(url: "hooks.example.com", headerName: "Authorization") != nil)
        #expect(WebhookConfig.problem(url: "https://hooks.example.com", headerName: "Bad Header") != nil)
        #expect(WebhookConfig.problem(url: "https://hooks.example.com", headerName: "Host") != nil)
        #expect(WebhookConfig.problem(url: "https://hooks.example.com", headerName: "X-Key\r\nEvil: 1") != nil)
    }

    @Test func coalescerUnit() {
        var c = PingCoalescer(interval: 60)
        let t = Date()
        c.add(NewMessagePing(chatID: "a", messageID: 1, receivedAt: t))
        c.add(NewMessagePing(chatID: "b", messageID: 2, receivedAt: t))
        #expect(c.due(now: t).map(\.messageID) == [1, 2])
        c.add(NewMessagePing(chatID: "a", messageID: 5, receivedAt: t))
        c.add(NewMessagePing(chatID: "a", messageID: 4, receivedAt: t))   // older id doesn't replace newer
        #expect(c.due(now: t.addingTimeInterval(59)).isEmpty)
        #expect(c.due(now: t.addingTimeInterval(60)).map(\.messageID) == [5])
        #expect(c.due(now: t.addingTimeInterval(200)).isEmpty)
    }
}

/// Real network smoke test against a local receiver. Runs only when MG_PING_URL is set, e.g.
/// MG_PING_URL=http://127.0.0.1:8799/hook swift test --filter realTransport
@Test(.enabled(if: ProcessInfo.processInfo.environment["MG_PING_URL"] != nil))
func realTransportSmoke() async throws {
    let url = URL(string: ProcessInfo.processInfo.environment["MG_PING_URL"]!)!
    let n = WebhookNotifier(permissions: try Harness().gate.permissions, openStore: { throw CancellationError() },
                            log: WebhookLog(url: nil))
    var result: WebhookLogEntry?
    n.sendTest(WebhookConfig(url: url, headerName: "Authorization", key: "local-test-key")) { result = $0 }
    for _ in 0..<300 where result == nil { try await Task.sleep(nanoseconds: 10_000_000) }
    #expect(result?.outcome == .sent)
}
