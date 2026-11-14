import Foundation
import Testing
@testable import VeilCore

/// The relay's "could this assistant open chat.db itself?" report, from the socket to the UI text.
/// Nothing here touches the real chat.db: the end-to-end test points the relay at a fixture file.
@Suite("Bypass check per assistant")
struct ClientCheckTests {
    static let initialize: JSON = ["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                   "params": ["clientInfo": ["name": "Grok Bot"], "protocolVersion": "2025-06-18"]]

    static func hello(_ readable: Bool) -> JSON { JSON.parse(Data(RelayHello.line(chatDBReadable: readable).utf8))! }

    @Test func helloIsCarriedToTheClientCheck() throws {
        let h = try Harness()
        var reported: [ClientCheck] = []
        h.server.onClientCheck = { reported.append($0) }
        let s = h.server.makeSession(transport: .relay)
        #expect(s.handle(Self.hello(true)) == nil)            // a notification: no reply, nothing sent back
        #expect(s.handle(Self.initialize)?["result"] != nil)
        #expect(reported.map(\.reach) == [.readable])
        #expect(reported.first?.name == "Grok Bot")
        #expect(h.server.connectedChecks.map(\.reach) == [.readable])
        #expect(reported.first?.headline == "Grok Bot runs with Full Disk Access")
        s.close()
        #expect(h.server.connectedChecks.isEmpty)
    }

    @Test func blockedRelayIsShownAsSafe() throws {
        let h = try Harness()
        let s = h.server.makeSession(transport: .relay)
        _ = s.handle(Self.hello(false)); _ = s.handle(Self.initialize)
        let c = try #require(h.server.connectedChecks.first)
        #expect(c.reach == .blocked && !c.canBypass)
    }

    @Test func oldRelayWithoutHelloCantBeChecked() throws {
        let h = try Harness()
        let s = h.server.makeSession(transport: .relay)
        _ = s.handle(Self.initialize)
        #expect(h.server.connectedChecks.first?.reach == .cantCheckOldRelay)
        #expect(h.server.connectedChecks.first?.headline == "Can't check Grok Bot")
    }

    /// The assistant's own lines pass through the relay, so a hello that isn't the first line is ignored:
    /// an assistant can't clear its own warning.
    @Test func assistantCantSendItsOwnHello() throws {
        let h = try Harness()
        let s = h.server.makeSession(transport: .relay)
        _ = s.handle(Self.hello(true))
        _ = s.handle(Self.hello(false))
        _ = s.handle(Self.initialize)
        #expect(h.server.connectedChecks.first?.reach == .readable)

        let late = h.server.makeSession(transport: .relay)
        _ = late.handle(Self.initialize)
        _ = late.handle(Self.hello(false))
        _ = late.handle(Self.initialize)
        #expect(late.reach == .cantCheckOldRelay)
    }

    @Test func httpClientsSayCantCheckEvenIfTheyClaimOtherwise() throws {
        let h = try Harness()
        let http = LocalHTTPServer(port: 8799, token: "t", server: h.server)
        var reported: [ClientCheck] = []
        h.server.onClientCheck = { reported.append($0) }
        func post(_ body: JSON) -> (String, [String: String], Data) {
            http.respond(HTTPRequest(method: "POST", path: "/mcp",
                                     headers: ["host": "127.0.0.1:8799", "authorization": "Bearer t"],
                                     body: Data(body.encoded().utf8)))
        }
        let (status, _, _) = post(Self.hello(false))
        #expect(status.hasPrefix("202"))
        _ = post(Self.initialize)
        #expect(reported.map(\.reach) == [.cantCheckHTTP])
        #expect(reported.first?.transport == .http)
        #expect(reported.first?.headline == "Can't check Grok Bot")
        #expect(reported.first?.canBypass == false)
    }

    @Test func helloLineMatchesWhatTheRelaySends() {
        // The relay has no VeilCore dependency and writes this line by hand; keep both in step.
        let relay = #"{"jsonrpc":"2.0","method":"veil/relayHello","params":{"chatDbReadable":true,"relayVersion":1}}"# + "\n"
        #expect(RelayHello.line(chatDBReadable: true) == relay)
    }

    @Test func storeRemembersPerNameAndListsWarningsFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("veil-checks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("client-checks.json")
        let store = ClientCheckStore(url: url)
        store.record(ClientCheck(name: "Alpha", transport: .relay, reach: .blocked))
        store.record(ClientCheck(name: "Zed Bot", transport: .relay, reach: .readable))
        store.record(ClientCheck(name: "Web", transport: .http, reach: .cantCheckHTTP))
        #expect(store.all.map(\.name) == ["Zed Bot", "Alpha", "Web"])
        // A later connection replaces the earlier check for the same name.
        store.record(ClientCheck(name: "Zed Bot", transport: .relay, reach: .blocked))
        #expect(store.bypassing.isEmpty)
        let reloaded = ClientCheckStore(url: url)
        #expect(reloaded.all.count == 3)
        reloaded.forget("Web")
        #expect(ClientCheckStore(url: url).all.map(\.name) == ["Alpha", "Zed Bot"])
    }

    // MARK: End to end, with the real relay binary

    static let relayBinary: URL? = {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(".build/debug/veil-mcp")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }()

    /// Runs the relay against a socket in a temp folder, with chat.db pointed at a fixture.
    func runRelay(chatDB: URL) throws -> ClientCheck? {
        let h = try Harness()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vr-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let sock = dir.appendingPathComponent("s.sock").path
        let server = UnixSocketServer(path: sock, server: h.server)
        try server.start()
        defer { server.stop() }
        let got = LockedBox<ClientCheck?>(nil)
        h.server.onClientCheck = { c in got.set(c) }

        let p = Process()
        p.executableURL = Self.relayBinary
        // VEIL_NO_LAUNCH: never start the real app, even if the test socket somehow isn't there.
        p.environment = ["VEIL_SOCKET": sock, "VEIL_CHAT_DB": chatDB.path, "VEIL_NO_LAUNCH": "1"]
        let input = Pipe(), output = Pipe()
        p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data((Self.initialize.encoded() + "\n").utf8))
        // Read the initialize reply, which proves the hello didn't disturb the MCP stream.
        var reply = Data()
        let deadline = Date().addingTimeInterval(10)
        while !reply.contains(0x0A), Date() < deadline {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            reply.append(chunk)
        }
        try? input.fileHandleForWriting.close()
        p.waitUntilExit()
        let line = try #require(JSON.parse(reply.prefix { $0 != 0x0A }))
        #expect(line["id"] == 1)
        #expect(line["result"]?["serverInfo"]?["name"] == "veil")
        return got.value
    }

    @Test(.enabled(if: relayBinary != nil)) func relayReportsAnOpenableDatabase() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("veil-relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("chat.db")
        try Data("not a database".utf8).write(to: fake)
        #expect(try runRelay(chatDB: fake)?.reach == .readable)

        // Same file, unreadable for us: what an assistant without Full Disk Access sees.
        chmod(fake.path, 0o000)
        #expect(try runRelay(chatDB: fake)?.reach == .blocked)
        chmod(fake.path, 0o600)
        #expect(try runRelay(chatDB: dir.appendingPathComponent("missing.db"))?.reach == .blocked)
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.lock(); defer { lock.unlock() }; return _value }
    func set(_ v: T) { lock.lock(); _value = v; lock.unlock() }
}

@Suite("Full Disk Access notice")
struct BypassNoticeTests {
    func fresh() -> (BypassAcknowledgements, UserDefaults, String) {
        let suite = "veil-test-acks-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        return (BypassAcknowledgements(defaults: d), d, suite)
    }

    @Test func wordingIsNeutral() {
        let c = ClientCheck(name: "Grok Bot", transport: .relay, reach: .readable)
        #expect(c.headline == "Grok Bot runs with Full Disk Access")
        #expect(c.detail == "So it could read Messages directly. Veil's limits only apply to what it asks Veil for.")
        #expect(ClientCheck.acknowledgedLine == "Has Full Disk Access (acknowledged)")
        for r in [ChatDBReach.readable, .blocked, .cantCheckHTTP, .cantCheckOldRelay] {
            let text = ClientCheck(name: "X", transport: .relay, reach: r).headline + ClientCheck(name: "X", transport: .relay, reach: r).detail
            #expect(!text.lowercased().contains("safe"))
            #expect(!text.lowercased().contains("warning"))
        }
    }

    @Test func acknowledgingQuietsOnlyThatAssistant() {
        let (acks, d, suite) = fresh(); defer { d.removePersistentDomain(forName: suite) }
        let grok = ClientCheck(name: "Grok Bot", transport: .relay, reach: .readable)
        let other = ClientCheck(name: "Other", transport: .relay, reach: .readable)
        #expect(acks.needsNotice(grok) && acks.needsNotice(other))
        acks.acknowledge("Grok Bot")
        #expect(!acks.needsNotice(grok))
        #expect(acks.needsNotice(other))
        // Kept across launches (same defaults).
        #expect(BypassAcknowledgements(defaults: d).isAcknowledged("Grok Bot"))
    }

    @Test func acknowledgementResetsWhenTheCheckGoesFromFalseToTrue() {
        let (acks, d, suite) = fresh(); defer { d.removePersistentDomain(forName: suite) }
        acks.acknowledge("Grok Bot")
        // Can't-check results don't touch it.
        acks.update(for: ClientCheck(name: "Grok Bot", transport: .http, reach: .cantCheckHTTP))
        acks.update(for: ClientCheck(name: "Grok Bot", transport: .relay, reach: .readable))
        #expect(acks.isAcknowledged("Grok Bot"))
        // Without Full Disk Access once, then with it again: the notice comes back.
        acks.update(for: ClientCheck(name: "Grok Bot", transport: .relay, reach: .blocked))
        let again = ClientCheck(name: "Grok Bot", transport: .relay, reach: .readable)
        acks.update(for: again)
        #expect(acks.needsNotice(again))
    }

    @Test func blockedAndCantCheckNeverNeedANotice() {
        let (acks, d, suite) = fresh(); defer { d.removePersistentDomain(forName: suite) }
        #expect(!acks.needsNotice(ClientCheck(name: "A", transport: .relay, reach: .blocked)))
        #expect(!acks.needsNotice(ClientCheck(name: "B", transport: .http, reach: .cantCheckHTTP)))
        #expect(!acks.needsNotice(ClientCheck(name: "C", transport: .relay, reach: .cantCheckOldRelay)))
    }

    @Test func clientNamesMatchTheAppTheyRunIn() {
        func app(_ name: String) -> FullDiskAccessGrant { FullDiskAccessGrant(client: "x", isPath: false, name: name, kind: .other) }
        #expect(app("Claude").matches(clientName: "claude-ai"))
        #expect(app("Cursor").matches(clientName: "cursor-vscode"))
        #expect(app("Grok Bot").matches(clientName: "Grok Bot"))
        #expect(!app("PhotoSync").matches(clientName: "Grok Bot"))
        #expect(!app("iTerm").matches(clientName: "claude-code"))
    }
}
