import Foundation

/// Model Context Protocol over JSON-RPC 2.0. Transport-agnostic: each connection gets a
/// `Session`, feeds it messages, and writes back whatever it returns.
public final class MCPServer {
    public let gate: Gate
    public var onSessionsChange: (() -> Void)?
    private let lock = NSLock()
    private var active: [UUID: String] = [:]

    public init(gate: Gate) { self.gate = gate }

    /// Names of currently connected clients (for the menu bar status line).
    public var connectedClients: [String] { lock.lock(); defer { lock.unlock() }; return Array(active.values) }

    public final class Session {
        let id = UUID()
        private let lock = NSLock()
        private var _clientName = "Unknown assistant"
        var clientName: String {
            get { lock.lock(); defer { lock.unlock() }; return _clientName }
            set { lock.lock(); _clientName = newValue; lock.unlock() }
        }
        weak var server: MCPServer?
        init(server: MCPServer) { self.server = server }
        public func handle(_ message: JSON) -> JSON? { server?.handle(message, session: self) }
        public func close() { server?.end(self) }
    }

    public func makeSession() -> Session { Session(server: self) }

    private func end(_ s: Session) {
        lock.lock(); active[s.id] = nil; lock.unlock(); onSessionsChange?()
    }

    func handle(_ msg: JSON, session: Session) -> JSON? {
        if case .array(let batch) = msg {
            let replies = batch.compactMap { handle($0, session: session) }
            return replies.isEmpty ? nil : .array(replies)
        }
        guard let method = msg["method"]?.string else {
            return msg["id"] == nil ? nil : error(msg["id"], -32600, "Invalid request")
        }
        let id = msg["id"]
        let params = msg["params"] ?? [:]
        switch method {
        case "initialize":
            if let name = params["clientInfo"]?["name"]?.string { session.clientName = Self.clientLabel(name) }
            lock.lock(); active[session.id] = session.clientName; lock.unlock(); onSessionsChange?()
            let version = params["protocolVersion"]?.string ?? "2025-06-18"
            return result(id, [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "veil", "title": "Veil", "version": "1.0.0"],
                "instructions": .string(Self.instructions),
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": .array(Self.tools)])
        case "tools/call":
            guard let name = params["name"]?.string else { return error(id, -32602, "Missing tool name") }
            let r = gate.call(tool: name, arguments: params["arguments"] ?? [:], client: session.clientName)
            return result(id, ["content": .array(r.content), "isError": .bool(r.isError)])
        default:
            if id == nil { return nil }   // notifications (e.g. notifications/initialized) need no reply
            return error(id, -32601, "Method not found: \(method)")
        }
    }

    private func result(_ id: JSON?, _ r: JSON) -> JSON { ["jsonrpc": "2.0", "id": id ?? .null, "result": r] }
    private func error(_ id: JSON?, _ code: Int, _ m: String) -> JSON {
        ["jsonrpc": "2.0", "id": id ?? .null, "error": ["code": JSON(code), "message": .string(m)]]
    }

    /// The client picks its own name, so treat it as untrusted: printable, short, and never "You".
    static func clientLabel(_ raw: String) -> String {
        let clean = String(raw.unicodeScalars.filter { !$0.properties.isWhitespace || $0 == " " }
            .filter { $0.properties.generalCategory != .control && $0.properties.generalCategory != .format }
            .map(Character.init)).trimmingCharacters(in: .whitespaces)
        let reserved = ["you", "me", "user", "owner", "veil", ""]
        return reserved.contains(clean.lowercased()) ? "Unknown assistant" : String(clean.prefix(40))
    }

    static let instructions = """
    Veil gives you access to the user's Apple Messages, but only the chats and actions the user has allowed. \
    Start with list_chats to see what's available. Locked chats show only a name and number. \
    Chats marked 'activity' share only when messages came and went (chat_activity), never what they say. \
    You cannot change permissions; if you need more access, ask the user to change it in the Veil menu bar app. \
    Sending always needs the user's approval for each message.
    """

    static func tool(_ name: String, _ title: String, _ desc: String, _ props: [String: JSON] = [:], required: [String] = [], readOnly: Bool = true) -> JSON {
        ["name": .string(name), "title": .string(title), "description": .string(desc),
         "inputSchema": ["type": "object", "properties": .object(props), "required": .array(required.map { .string($0) }), "additionalProperties": false],
         "annotations": ["readOnlyHint": .bool(readOnly), "openWorldHint": false]]
    }
    static let chatID: JSON = ["type": "string", "description": "A chat_id from list_chats."]

    static let tools: [JSON] = [
        tool("list_chats", "List chats",
             "Lists the user's conversations with what you're allowed to do in each. Locked chats show only name and number.",
             ["query": ["type": "string", "description": "Optional filter by name, number or email."]]),
        tool("read_chat", "Read a chat",
             "Returns messages from one chat, oldest to newest. Needs 'read' access. Pass older_messages_cursor as before_message_id to page back through full history.",
             ["chat_id": chatID, "limit": ["type": "integer", "description": "1-200, default 40."],
              "before_message_id": ["type": "integer", "description": "Return messages older than this id."]], required: ["chat_id"]),
        tool("search_messages", "Search messages",
             "Searches message text, only in chats where the user allows reading.",
             ["query": ["type": "string"], "chat_id": ["type": "string", "description": "Optional: search one chat."],
              "limit": ["type": "integer", "description": "1-50, default 20."]], required: ["query"]),
        tool("waiting_on_reply", "Who's waiting on a reply",
             "Chats (with 'waiting_on_reply' or 'activity' access) where the last message is from someone else. Includes the last message text only if reading is also allowed.",
             ["days": ["type": "integer", "description": "Look back this many days (default 14, max 90)."]]),
        tool("chat_activity", "See a chat's activity",
             "When messages came and went in one chat: time, direction (incoming or from_me) and, in groups, who sent each one. Never message text, attachments or reactions. Also returns last_incoming_at, last_reply_at (the user's last message) and replied_since_last_incoming. Needs 'activity' or 'read' access.",
             ["chat_id": chatID, "since": ["type": "string", "description": "Optional ISO 8601 time; only messages at or after it."],
              "limit": ["type": "integer", "description": "1-200, default 50."],
              "before_message_id": ["type": "integer", "description": "Page back: pass older_messages_cursor from the last call."]], required: ["chat_id"]),
        tool("list_attachments", "List attachments",
             "Lists photos and files in a chat. Needs 'attachments' access.",
             ["chat_id": chatID, "limit": ["type": "integer"], "before_attachment_id": ["type": "integer"]], required: ["chat_id"]),
        tool("get_attachment", "Get an attachment",
             "Returns one photo (as an image) or file. Needs 'attachments' access for its chat.",
             ["attachment_id": ["type": "integer"]], required: ["attachment_id"]),
        tool("draft_reply", "Save a draft reply",
             "Saves a draft reply for the user to review in Veil. Never sends anything. Needs 'draft_reply' access.",
             ["chat_id": chatID, "text": ["type": "string"]], required: ["chat_id", "text"], readOnly: false),
        tool("request_send", "Ask to send a message",
             "Asks the user to approve sending this exact message. Nothing is sent unless they click Send, except in chats where the user turned on auto-send ('auto_send' in list_chats): there it is sent right away, up to a rate limit, and the status says so. Needs 'request_send' access.",
             ["chat_id": chatID, "text": ["type": "string"]], required: ["chat_id", "text"], readOnly: false),
        tool("check_send_status", "Check a send request",
             "Returns whether a request_send was sent, declined, failed, or is still waiting for the user.",
             ["request_id": ["type": "string"]], required: ["request_id"]),
    ]
}
