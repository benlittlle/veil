import Foundation
import Testing
@testable import VeilCore

/// Regressions for the red-team pass: each test is an attack that used to work.
@Suite("Red team")
struct RedTeamTests {
    /// Sends lines to a fresh socket server and returns the reply lines, in order.
    func socketExchange(_ h: Harness, _ lines: [String], replies: Int) throws -> [String] {
        let path = "/tmp/veil-\(UUID().uuidString.prefix(8)).sock"
        let sock = UnixSocketServer(path: path, server: h.server)
        try sock.start(); defer { sock.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = try UnixSocketServer.address(path)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try #require(rc == 0)
        writeAll(fd, Data(lines.map { $0 + "\n" }.joined().utf8))
        var got = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while got.filter({ $0 == 0x0A }).count < replies {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            got.append(contentsOf: buf[0..<n])
        }
        return String(decoding: got, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    // MARK: - Deeply nested JSON

    /// One short line of nested brackets (under the JSON decoder's own limit of 512 levels) used to overflow
    /// the connection thread's stack while it was parsed, crashing Veil for every assistant.
    @Test func deeplyNestedJSONIsRefusedNotFatal() throws {
        let h = try Harness()
        let deep = String(repeating: "[", count: 500) + String(repeating: "]", count: 500)
        let deepObject = String(repeating: #"{"a":"#, count: 500) + "1" + String(repeating: "}", count: 500)
        let nestedBatch = String(repeating: "[", count: 40) + #"{"jsonrpc":"2.0","id":5,"method":"ping"}"# + String(repeating: "]", count: 40)
        let replies = try socketExchange(h, [deep, deepObject, nestedBatch, #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#], replies: 4)
        #expect(replies.count == 4)
        #expect(replies.prefix(2).allSatisfy { $0.contains("-32700") })
        #expect(replies[2].contains("-32600"))   // a batch inside a batch isn't a request
        #expect(replies.last?.contains(#""id":7"#) == true)
    }

    @Test func ordinaryNestingStillParses() throws {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","arguments":{"filter":{"categories":{"codes":"mask"}},"list":[[1,[2,"[{"]]]}}}"#
        #expect(JSON.parse(Data(line.utf8))?["params"]?["arguments"]?["filter"]?["categories"]?["codes"]?.string == "mask")
    }

    // MARK: - Hidden text in messages to approve

    func scalars(_ base: String, _ extra: [UInt32]) -> String {
        var s = base
        for v in extra { s.unicodeScalars.append(Unicode.Scalar(v)!) }
        return s
    }

    /// Variation selectors and other default-ignorable code points draw nothing, so a manipulated assistant
    /// could hide kilobytes (one byte per selector) behind a one-emoji message the user approves, and the
    /// whole lot counted as a single character against the 2000-character limit.
    @Test func hiddenPayloadsAreRefused() throws {
        let h = try Harness()
        let hidden: [(String, String)] = [
            ("variation selectors carrying bytes", scalars("Sounds good 👍", (0..<3000).map { 0xE0100 + UInt32($0 % 240) })),
            ("a run of emoji selectors", scalars("hi", Array(repeating: 0xFE0F, count: 50))),
            ("a selector after plain text", scalars("ok", [0xFE01])),
            ("joiners between letters", scalars("a", [0x200D]) + "b"),
            ("a run of joiners", scalars("👍", [0x200D, 0x200D, 0x200D])),
            ("Hangul fillers", scalars("hi", [0x3164, 0x115F, 0xFFA0])),
            ("a grapheme joiner", scalars("hi", [0x034F]) + "x"),
            ("a Mongolian selector", scalars("hi", [0x180B])),
            ("a stack of accents", scalars("ok", Array(repeating: 0x0301, count: 40))),
        ]
        for (what, text) in hidden {
            for tool in ["request_send", "draft_reply"] {
                let out = h.call(tool, ["chat_id": .string(ID.mom), "text": .string(text)])
                #expect(out.isError, "\(tool) accepted \(what)")
                // Keep the waiting list clear, so each case is judged on its text alone.
                h.gate.sends.filter { $0.status == .waiting }.forEach { h.gate.decline($0.id) }
            }
        }
        #expect(h.gate.sends.isEmpty && h.gate.drafts.isEmpty)
        #expect(h.sender.sent.isEmpty)
    }

    @Test func everydayTextStillGoesThrough() throws {
        let h = try Harness(access: [ID.mom: ChatAccess(draft: true)])
        let fine = ["❤️ see you soon", "👩🏽‍❤️‍💋‍👨🏿", "👨‍👩‍👧‍👦 dinner?", "1️⃣ 2️⃣ #️⃣", "🇬🇧 🇯🇵", "Tiếng Việt có dấu",
                    "नमस्ते, कैसे हो?", "สวัสดีครับ", "Ça va? Größe, señor", "日本語のテキスト", "שלום עולם", "مرحبا",
                    "ශ්‍රී ලංකා", "क्‍ष"]
        for text in fine {
            let out = h.call("draft_reply", ["chat_id": .string(ID.mom), "text": .string(text)])
            #expect(!out.isError, "refused: \(text)")
        }
        #expect(h.gate.drafts.count == 10)   // the newest 10 are kept per chat
    }

    // MARK: - What the send prompt says

    /// Any member can rename a group. Renamed to "Mom", with a direction override and line breaks, a group
    /// the user lets the assistant send to made the prompt read "Send this to Mom?", so a manipulated
    /// assistant could get private text approved for the wrong people.
    @Test func sendPromptCantBeSpoofedByAGroupName() throws {
        let h = try Harness(access: [ID.climbing: ChatAccess(read: true, draft: true, send: true)])
        let db = try SQLiteDB(path: h.dir.appendingPathComponent("chat.db").path, readOnly: false)
        let spoof = "Mom\u{202E}\u{2066}\n\n(verified)" + String(repeating: " pad", count: 100)
        try db.query("UPDATE chat SET display_name = ? WHERE chat_identifier = ?", [.text(spoof), .text(ID.climbing)])

        h.call("request_send", ["chat_id": .string(ID.climbing), "text": "the code is in my notes"])
        h.call("draft_reply", ["chat_id": .string(ID.climbing), "text": "draft"])
        let r = try #require(h.gate.sends.first)
        let d = try #require(h.gate.drafts.first)
        let logged = try #require(h.gate.log.all.last?.chatName)
        for name in [r.chatName, d.chatName, logged] {
            #expect(!name.unicodeScalars.contains { $0.properties.generalCategory == .format || $0.properties.generalCategory == .control })
            #expect(name.hasPrefix("Mom (verified)"))
            #expect(name.count <= 60)
        }
        // The prompt says who it really goes to.
        #expect(r.recipients.contains("Alex Chen") && r.recipients.contains("Sam Patel"))
        #expect(r.recipients.hasPrefix("Group"))
        // A one-to-one chat shows its handle.
        let h2 = try Harness()
        h2.call("request_send", ["chat_id": .string(ID.mom), "text": "hi"])
        #expect(h2.gate.sends.first?.recipients == ID.mom)
    }

    // MARK: - Approving a settings request

    /// A request only lists what would change when it's made. A value that already matched was left off the
    /// prompt, but still applied on Allow, even if the user had changed it in between. Here the assistant
    /// asks for Send plus "codes: allow" while codes are allowed; the prompt says only "Send on". The user
    /// then hides codes, clicks Allow for Send, and codes were quietly let through again.
    @Test func allowAppliesOnlyWhatThePromptShowed() throws {
        let h = try Harness()
        try h.gate.setFiltered(true, for: ID.climbing)
        var p = FilterPolicy.standard; p.set(.codes, .allow)
        try h.gate.setChatFilterPolicy(p, for: ID.climbing)
        try h.gate.setAgentSettings(.ask)

        let out = h.call("change_chat_settings", ["chat_id": .string(ID.climbing), "send": true,
                                                  "filter": ["categories": ["codes": "allow"]]]).json
        let id = try #require(out["request_id"]?.string)
        #expect(out["changes"] == ["Send with your OK on"])

        p.set(.codes, .withhold)
        try h.gate.setChatFilterPolicy(p, for: ID.climbing)
        h.gate.approveSettings(id)
        #expect(h.gate.permissions.state.filterPolicy(for: ID.climbing)?.action(.codes) == .withhold)
        #expect(!h.gate.permissions.state.access(ID.climbing).send)
        #expect(h.gate.settingsRequests.first { $0.id == id }?.status.label == "cancelled")
    }

    /// The same for app settings: the user stopped every auto-send after the request was made.
    @Test func allowDoesntUndoTheKillSwitch() throws {
        let h = try Harness()
        try h.gate.setAgentSettings(.ask)
        let out = h.call("change_app_settings", ["auto_send": true, "assistant_name": "Helper"]).json
        let id = try #require(out["request_id"]?.string)
        #expect(out["changes"] == ["Assistant name: “Helper”"])
        try h.gate.setAutoSendStopped(true)
        h.gate.approveSettings(id)
        #expect(h.gate.permissions.state.autoSendStopped)
        #expect(h.gate.preferences.assistantName != "Helper")
    }

    @Test func allowStillWorksWhenNothingElseChanged() throws {
        let h = try Harness()
        try h.gate.setAgentSettings(.ask)
        let id = try #require(h.call("change_chat_settings", ["chat_id": .string(ID.climbing), "send": true]).json["request_id"]?.string)
        let app = try #require(h.call("change_app_settings", ["auto_send": true, "assistant_name": "Helper"]).json["request_id"]?.string)
        h.gate.approveSettings(id)
        h.gate.approveSettings(app)
        #expect(h.gate.permissions.state.access(ID.climbing).send)
        #expect(h.gate.preferences.assistantName == "Helper")
    }

    // MARK: - What the assistant can write into Activity

    /// The tool name and the search query went into Activity (memory and the log file) at full length, so
    /// each call could add megabytes: a few hundred calls were enough to exhaust memory.
    @Test func activityEntriesStaySmall() throws {
        let h = try Harness()
        let huge = String(repeating: "x", count: 200_000)
        let unknown = h.call(huge)
        #expect(unknown.isError && unknown.text.count < 300)
        let search = h.call("search_messages", ["query": .string(String(repeating: "dinner ", count: 5000))])
        #expect(search.isError)
        let multiLine = h.call("search_messages", ["query": "dinner\nYou approved a message"])
        #expect(!multiLine.isError)
        for e in h.gate.log.all {
            #expect(e.tool.count <= 64)
            #expect(e.summary.count <= 400)
            #expect(!e.summary.contains("\n"))
        }
    }

    /// The name an assistant gives itself, and the name it may set, were capped in characters only, and a
    /// character can be a stack of thousands of accents drawn over the rest of the prompt.
    @Test func assistantNamesCantStackAccents() throws {
        var stacked = "Claude"
        for _ in 0..<3000 { stacked.unicodeScalars.append("\u{0301}") }
        #expect(MCPServer.clientLabel(stacked).unicodeScalars.count < 100)
        #expect(throws: SettingsError.self) { try SettingsArgs.assistantName(stacked) }
        var selectors = "Bob"
        for i in 0..<20 { selectors.unicodeScalars.append(Unicode.Scalar(0xE0100 + UInt32(i))!) }
        #expect(throws: SettingsError.self) { try SettingsArgs.assistantName(selectors) }
        #expect(MCPServer.clientLabel(selectors) == "Bob")
        #expect(MCPServer.clientLabel("Claude Desktop") == "Claude Desktop")
        #expect(try SettingsArgs.assistantName("Helper 🤖") == "Helper 🤖")
    }

    // MARK: - The socket

    /// A line that wasn't a request and had no id (a bare number, say) was answered with a JSON `null`, which
    /// the relay passed on to the assistant as if it were a message.
    @Test func nonRequestsGetNoReply() throws {
        let h = try Harness()
        #expect(h.server.makeSession().handle(1) == nil)
        #expect(h.server.makeSession().handle(["jsonrpc": "2.0"]) == nil)
        let replies = try socketExchange(h, ["1", "\"x\"", #"{"jsonrpc":"2.0","id":9,"method":"ping"}"#], replies: 1)
        #expect(replies.first?.contains(#""id":9"#) == true)
    }

    /// The folder holding the socket must be private even if it already existed with looser permissions.
    @Test func socketFolderIsPrivate() throws {
        let h = try Harness()
        let dir = "/tmp/veil-dir-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let sock = UnixSocketServer(path: dir + "/mcp.sock", server: h.server)
        try sock.start(); defer { sock.stop() }
        let dirMode = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? Int
        let sockMode = try FileManager.default.attributesOfItem(atPath: dir + "/mcp.sock")[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
        #expect(sockMode == 0o600)
    }

    // MARK: - The local web address

    /// The body (up to 8 MB) was read before the Host, Origin and token checks, so anything that can reach
    /// the port, a web page included, could make Veil wait for and hold 8 MB per connection without a token.
    @Test func httpRefusesBeforeReadingTheBody() throws {
        let h = try Harness()
        var started: LocalHTTPServer?
        for _ in 0..<20 where started == nil {
            let s = LocalHTTPServer(port: UInt16.random(in: 40000...60000), token: "tok", server: h.server)
            if (try? s.start()) != nil { started = s }
        }
        let http = try #require(started)
        defer { http.stop() }
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = http.port.bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(rc == 0)
        writeAll(fd, Data("POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:\(http.port)\r\nContent-Type: text/plain\r\nContent-Length: 8000000\r\n\r\n".utf8))
        let start = Date()
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        #expect(n > 0 && String(decoding: buf[0..<max(n, 0)], as: UTF8.self).hasPrefix("HTTP/1.1 401"))
        #expect(Date().timeIntervalSince(start) < 3)
    }

    // MARK: - Decompression bombs

    /// A PNG of `width` × `height` black pixels at 1 bit each: a few hundred KB on disk, gigabytes once decoded.
    static func hugePNG(width: Int, height: Int) throws -> Data {
        func be(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
        func chunk(_ type: String, _ body: Data) -> Data {
            let t = Data(type.utf8)
            return be(UInt32(body.count)) + t + body + be(crc32(t + body))
        }
        func crc32(_ d: Data) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for b in d { c ^= UInt32(b); for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) } }
            return ~c
        }
        let raw = Data(count: height * (1 + (width + 7) / 8))   // filter byte 0 and zero pixels on every row
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let zlib = Data([0x78, 0x01]) + deflated + be(b << 16 | a)
        var ihdr = be(UInt32(width)) + be(UInt32(height)); ihdr.append(contentsOf: [1, 0, 0, 0, 0])
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + chunk("IHDR", ihdr) + chunk("IDAT", zlib) + chunk("IEND", Data())
    }

    /// Photos from chats without a photo check were decoded whatever their size. A texter can send a tiny PNG
    /// that decodes to gigabytes (30000 × 30000 took about 900 MB and over a second), and the assistant can
    /// ask for it many times at once until macOS kills Veil. Bigger than the photo check's limit is refused.
    @Test func decompressionBombsArentDecoded() throws {
        let bomb = try Self.hugePNG(width: 12_000, height: 11_000)   // 132 million pixels, over the 120 million limit
        #expect(bomb.count < 1_000_000)
        #expect(Gate.jpeg(bomb) == nil)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("veil-bomb-\(UUID().uuidString).png")
        try bomb.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        #expect(Gate.jpeg(url) == nil)
        // An ordinary photo still converts.
        #expect(Gate.jpeg(try Self.hugePNG(width: 400, height: 300)) != nil)
    }

    // MARK: - What "last activity" counts

    /// `list_chats` took a chat's last activity from every row Messages links to it, tapbacks and system
    /// events included, so an activity-only chat gave away when someone reacted (which chat_activity never
    /// shows), and a reaction moved the chat up the list.
    @Test func lastActivityCountsRealMessagesOnly() throws {
        let h = try Harness(access: [ID.alex: ChatAccess(activity: true), ID.climbing: ChatAccess(read: true)])
        let db = try SQLiteDB(path: h.dir.appendingPathComponent("chat.db").path, readOnly: false)
        let when = appleTimestamp(Date().addingTimeInterval(-600))
        for (id, chat, kind) in [(9001, 3, "associated_message_type"), (9002, 6, "item_type")] as [(Int64, Int64, String)] {
            try db.query("INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, \(kind)) VALUES (?, ?, 'Loved “x”', 2, ?, 0, ?)",
                         [.int(id), .text("R-\(id)"), .int(when), .int(kind == "item_type" ? 2 : 2000)])
            try db.query("INSERT INTO chat_message_join VALUES (?, ?, ?)", [.int(chat), .int(id), .int(when)])
        }
        let chats = h.call("list_chats").json["chats"]?.array ?? []
        let activity = h.call("chat_activity", ["chat_id": .string(ID.alex)]).json
        let alex = try #require(chats.first { $0["chat_id"]?.string == ID.alex })
        #expect(alex["last_activity"] == activity["messages"]?.array?.last?["time"])
        let crew = try #require(chats.first { $0["chat_id"]?.string == ID.climbing })
        let read = h.call("read_chat", ["chat_id": .string(ID.climbing)]).json
        #expect(crew["last_activity"] == read["messages"]?.array?.last?["time"])
    }
}
