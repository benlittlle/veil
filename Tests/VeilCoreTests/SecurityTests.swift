import Foundation
import Testing
@testable import VeilCore

@Suite("Permission file integrity")
struct IntegrityTests {
    @Test func editedFileFailsClosed() throws {
        let h = try Harness()
        // Someone flips the therapist chat on by editing the JSON directly.
        var text = try String(contentsOf: h.permissionsURL, encoding: .utf8)
        text = text.replacingOccurrences(of: "\"paused\" : false", with: "\"paused\" : false, \"x\": 1")
        var file = try #require(JSON.parse(Data(text.utf8)))
        if case .object(var o) = file, case .object(var state)? = o["state"], case .object(var chats)? = state["chats"] {
            chats[ID.therapist] = ["read": true, "waiting": true, "draft": true, "send": true, "attachments": true, "hidden": false]
            state["chats"] = .object(chats); o["state"] = .object(state); file = .object(o)
        }
        try Data(file.encoded().utf8).write(to: h.permissionsURL)

        let reloaded = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        guard case .tampered = reloaded.integrity else { Issue.record("tamper not detected"); return }
        #expect(reloaded.state.access(ID.therapist) == .none)
        #expect(reloaded.state.access(ID.mom) == .none)
    }

    @Test func rollbackToOlderFileIsDetected() throws {
        let h = try Harness()
        let old = try Data(contentsOf: h.permissionsURL)     // Mom has send on here
        try h.gate.setAccess(ChatAccess(read: true), for: ID.mom)
        try old.write(to: h.permissionsURL)
        let reloaded = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        #expect(reloaded.integrity == .tampered("The permissions file was replaced with an older copy."))
    }

    @Test func untouchedFileLoads() throws {
        let h = try Harness()
        let reloaded = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        #expect(reloaded.integrity == .ok)
        #expect(reloaded.state.access(ID.mom).send)
    }

    @Test func gateRefusesEverythingWhileTampered() throws {
        let h = try Harness()
        try Data("{}".utf8).write(to: h.permissionsURL)
        let tampered = PermissionStore(url: h.permissionsURL, secrets: h.secrets)
        let gate = Gate(permissions: tampered, log: AccessLog(url: nil), contacts: StaticContacts([:]), sender: RecordingSender(),
                        openStore: { try h.gate.messagesStore() })
        #expect(gate.call(tool: "list_chats", arguments: [:], client: "t").isError)
    }

    @Test func newChatsDefaultToEverythingOff() throws {
        let h = try Harness(access: [:])
        let chats = h.call("list_chats").json["chats"]?.array ?? []
        #expect(chats.count == 6)
        #expect(chats.allSatisfy { $0["allowed"] == .array([]) })
        #expect(!h.call("list_chats").raw.contains(secret))
    }
}

@Suite("MCP surface")
struct ProtocolTests {
    @Test func noToolCanChangePermissions() throws {
        let names = Set(MCPServer.tools.compactMap { $0["name"]?.string })
        #expect(names == ["list_chats", "read_chat", "search_messages", "waiting_on_reply", "list_attachments",
                          "get_attachment", "draft_reply", "request_send", "check_send_status", "chat_activity"])
        let h = try Harness()
        for t in ["set_permissions", "update_access", "approve_send", "setAccess", "set_activity", "enable_activity"] {
            #expect(h.call(t, ["chat_id": .string(ID.therapist)]).isError)
        }
    }

    @Test func jsonRPCRoundTrip() throws {
        let h = try Harness()
        let s = h.server.makeSession()
        let initR = s.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                              "params": ["protocolVersion": "2025-06-18", "clientInfo": ["name": "Assistant"]]])
        #expect(initR?["result"]?["serverInfo"]?["name"]?.string == "veil")
        #expect(s.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)
        #expect(s.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"])?["result"]?["tools"]?.array?.count == 10)
        let call = s.handle(["jsonrpc": "2.0", "id": 3, "method": "tools/call",
                             "params": ["name": "read_chat", "arguments": ["chat_id": .string(ID.family)]]])
        #expect(call?["result"]?["isError"] == true)
        #expect(h.gate.log.all.last?.client == "Assistant")
        #expect(s.handle(["jsonrpc": "2.0", "id": 4, "method": "nope"])?["error"]?["code"] == -32601)
    }

    @Test func unixSocketEndToEnd() throws {
        let h = try Harness()
        let path = "/tmp/veil-\(UUID().uuidString.prefix(8)).sock"
        let sock = UnixSocketServer(path: path, server: h.server)
        try sock.start()
        defer { sock.stop() }
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
        var addr = try UnixSocketServer.address(path)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        #expect(rc == 0)
        let req = #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"list_chats","arguments":{}}}"# + "\n"
        writeAll(fd, Data(req.utf8))
        var buf = [UInt8](repeating: 0, count: 65536); var got = Data()
        while !got.contains(0x0A) { let n = read(fd, &buf, buf.count); if n <= 0 { break }; got.append(contentsOf: buf[0..<n]) }
        let reply = try #require(JSON.parse(got))
        #expect(reply["id"] == 7)
        #expect(reply["result"]?["isError"] == false)
        #expect(!String(decoding: got, as: UTF8.self).contains(secret))
    }

    @Test func httpRequiresTokenAndRejectsBrowsers() throws {
        let h = try Harness()
        let http = LocalHTTPServer(port: 0, token: "tok", server: h.server)
        func req(_ headers: [String: String]) -> String {
            var r = HTTPRequest(method: "POST", path: "/mcp")
            r.headers = headers
            r.body = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
            return http.respond(r).0
        }
        #expect(req(["host": "127.0.0.1:0"]) == "401 Unauthorized")
        #expect(req(["host": "127.0.0.1:0", "authorization": "Bearer wrong"]) == "401 Unauthorized")
        #expect(req(["host": "evil.example:0", "authorization": "Bearer tok"]) == "421 Misdirected Request")
        #expect(req(["host": "127.0.0.1:0", "authorization": "Bearer tok", "origin": "https://evil.example"]) == "403 Forbidden")
        #expect(req(["host": "127.0.0.1:0", "authorization": "Bearer tok"]) == "200 OK")
    }

    @Test func httpRoundTripOverLoopback() throws {
        let h = try Harness()
        let port = UInt16.random(in: 40000...60000)
        let http = LocalHTTPServer(port: port, token: "tok", server: h.server)
        try http.start()
        defer { http.stop() }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        req.httpMethod = "POST"
        req.setValue("Bearer tok", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read_chat","arguments":{"chat_id":"chat200"}}}"#.utf8)
        let done = DispatchSemaphore(value: 0)
        var body = Data(); var status = 0
        URLSession.shared.dataTask(with: req) { d, r, _ in
            body = d ?? Data(); status = (r as? HTTPURLResponse)?.statusCode ?? 0; done.signal()
        }.resume()
        #expect(done.wait(timeout: .now() + 5) == .success)
        #expect(status == 200)
        let reply = try #require(JSON.parse(body))
        #expect(reply["result"]?["isError"] == true)
        #expect(!String(decoding: body, as: UTF8.self).contains(secret))
    }
}
