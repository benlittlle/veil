import Foundation
import Testing
@testable import VeilCore

/// Regressions for the robustness review.
@Suite("Robustness")
struct RobustnessTests {
    /// A Keychain that can be made to fail on load or save.
    final class FlakySecrets: SecretStore {
        var inner = MemorySecretStore()
        var failLoad = false, failSave = false
        struct Locked: Error {}
        func load() throws -> (Data, UInt64)? { if failLoad { throw Locked() }; return try inner.load() }
        func save(key: Data, generation: UInt64) throws { if failSave { throw Locked() }; try inner.save(key: key, generation: generation) }
    }

    func tempFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("veil-\(UUID().uuidString).json") }

    @Test func lockedKeychainAtLaunchFailsClosedAndRecovers() throws {
        let url = tempFile(), secrets = FlakySecrets()
        try PermissionStore(url: url, secrets: secrets).update { $0.chats["a"] = ChatAccess(read: true) }
        secrets.failLoad = true
        let store = PermissionStore(url: url, secrets: secrets)
        guard case .tampered = store.integrity else { Issue.record("should fail closed"); return }
        #expect(store.state.access("a") == .none)
        #expect(throws: (any Error).self) { try store.update { $0.paused = true } }   // never signs with an empty key
        #expect(throws: (any Error).self) { try store.reset() }
        secrets.failLoad = false
        try store.reset()                                                          // works once the Keychain is back
        #expect(store.integrity == .ok)
        #expect(PermissionStore(url: url, secrets: secrets).integrity == .ok)       // and survives a relaunch
    }

    @Test func keychainSaveFailureDoesNotLookLikeTampering() throws {
        let url = tempFile(), secrets = FlakySecrets()
        let store = PermissionStore(url: url, secrets: secrets)
        try store.update { $0.chats["a"] = ChatAccess(read: true) }
        secrets.failSave = true
        #expect(throws: (any Error).self) { try store.update { $0.chats["b"] = ChatAccess(read: true) } }
        secrets.failSave = false
        let relaunched = PermissionStore(url: url, secrets: secrets)
        #expect(relaunched.integrity == .ok)
        #expect(relaunched.state.access("b").read)   // the file write landed; the Keychain catches up
    }

    @Test func keychainRejectsBadKeys() {
        #expect(throws: (any Error).self) { try KeychainSecretStore(service: "unused-\(UUID())").save(key: Data(), generation: 1) }
    }

    @Test func socketKeepsServingAfterAbruptClients() throws {
        let h = try Harness()
        let path = "/tmp/veil-\(UUID().uuidString.prefix(8)).sock"
        let sock = UnixSocketServer(path: path, server: h.server)
        try sock.start(); defer { sock.stop() }
        for _ in 0..<100 {   // connect and hang up immediately, repeatedly
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = try UnixSocketServer.address(path)
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            close(fd)
        }
        // The server clears the hung-up connections at its own pace: while its listen queue is full or
        // it's at its connection cap, a new client is turned away. Once it has caught up it must answer.
        func ping() throws -> Bool {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
            var nosig: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
            var addr = try UnixSocketServer.address(path)
            guard withUnsafePointer(to: &addr, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }) == 0 else { return false }
            writeAll(fd, Data((#"{"jsonrpc":"2.0","id":1,"method":"ping"}"# + "\n").utf8))
            var buf = [UInt8](repeating: 0, count: 4096)
            let n = read(fd, &buf, buf.count)
            return n > 0 && String(decoding: buf[0..<n], as: UTF8.self).contains(#""id":1"#)
        }
        let deadline = Date().addingTimeInterval(20)
        var answered = try ping()
        while !answered, Date() < deadline { usleep(50_000); answered = try ping() }
        #expect(answered, "the server stopped answering after abrupt clients")
    }

    @Test func draftsAreCapped() throws {
        let h = try Harness()
        for i in 0..<30 { h.call("draft_reply", ["chat_id": .string(ID.mom), "text": .string("draft \(i)")]) }
        #expect(h.gate.drafts.count == 10)
        #expect(h.gate.drafts.first?.text == "draft 29")
    }

    @Test func finishedSendsAreForgotten() throws {
        let h = try Harness()
        let id = try #require(h.call("request_send", ["chat_id": .string(ID.mom), "text": "hi"]).json["request_id"]?.string)
        h.call("request_send", ["chat_id": .string(ID.mom), "text": "still waiting"])
        h.gate.decline(id)
        h.gate.pruneFinishedSends(olderThan: 0)
        #expect(h.gate.sends.map(\.text) == ["still waiting"])
    }

    @Test func assistantNeverSeesInternalErrors() throws {
        let h = try Harness()
        let gate = Gate(permissions: h.gate.permissions, log: AccessLog(url: nil), contacts: StaticContacts([:]), sender: RecordingSender(),
                        openStore: { throw NSError(domain: "x", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open /Users/someone/Library/Messages/chat.db"]) })
        let out = Harness.Out(result: gate.call(tool: "list_chats", arguments: [:], client: "t"))
        #expect(out.isError)
        #expect(!out.text.contains("/Users/"))
    }

    @Test func attachmentListHasACursor() throws {
        let h = try Harness()
        let out = h.call("list_attachments", ["chat_id": .string(ID.mom), "limit": 1]).json
        #expect(out["older_attachments_cursor"] != nil)
    }

    @Test func logRotatesAndClears() throws {
        let url = tempFile()
        let log = AccessLog(url: url)
        let big = String(repeating: "x", count: 2000)
        for _ in 0..<2500 { log.append(LogEntry(date: Date(), client: "t", tool: "read_chat", chatID: nil, chatName: nil, outcome: .allowed, summary: big)) }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(size < 6_000_000)
        #expect(AccessLog(url: url).all.count <= 2000)
        log.clear()
        #expect(log.all.isEmpty && !FileManager.default.fileExists(atPath: url.path))
    }
}
