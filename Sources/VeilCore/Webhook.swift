import Foundation
import Security

// New-message pings.
//
// When someone texts a chat that has Read or Activity turned on, Veil POSTs a tiny ping to
// a webhook the user configured, so their assistant knows to look. In chats with Activity on, the user's own
// messages ping too (direction "from_me", if the setting allows), so the assistant can tell they
// replied. The ping carries no message text, no names and no attachments, only which chat, which
// message number and which direction. The assistant then reads through
// the normal, permission-checked MCP tools. Nothing here is reachable from MCP: the gate and
// the MCP server hold no reference to it, and its settings are only changed by the app UI.

/// Where and how to send pings. Built by the app from its settings and the Keychain.
public struct WebhookConfig: Equatable, Sendable {
    public var url: URL
    public var headerName: String
    public var key: String
    /// Ping for the user's own messages too, in chats with Activity on.
    public var pingReplies: Bool

    public init(url: URL, headerName: String, key: String, pingReplies: Bool = true) {
        self.url = url; self.headerName = headerName; self.key = key; self.pingReplies = pingReplies
    }

    /// `Authorization` gets "Bearer <key>"; any other header gets the key as-is.
    var headerValue: String {
        headerName.caseInsensitiveCompare("Authorization") == .orderedSame ? "Bearer \(key)" : key
    }

    /// Returns a plain-language problem, or nil if the settings are usable.
    /// HTTPS is required so the key is never sent in the clear, except to this Mac itself.
    public static func problem(url: String, headerName: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard let u = URL(string: trimmed), let scheme = u.scheme?.lowercased(), let host = u.host, !host.isEmpty else {
            return "Enter the full webhook address, starting with https://"
        }
        if u.user != nil || u.password != nil { return "Put the key in the Key field, not in the address." }
        let local = ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
        guard scheme == "https" || (scheme == "http" && local) else {
            return "The address must start with https:// (plain http is only allowed for this Mac)."
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-")
        let reserved = ["host", "content-type", "content-length", "connection", "transfer-encoding", "cookie"]
        if headerName.isEmpty || headerName.count > 64 || headerName.unicodeScalars.contains(where: { !allowed.contains($0) })
            || reserved.contains(headerName.lowercased()) {
            return "The header name can only use letters, numbers and dashes (for example Authorization)."
        }
        return nil
    }
}

public struct NewMessagePing: Equatable, Sendable {
    public let chatID: String
    public let messageID: Int64
    public let receivedAt: Date
    public var fromMe = false
}

/// At most one ping per chat per `interval`. A burst becomes one ping now and, if more arrive
/// during the quiet period, one more at the end of it carrying the newest message id.
public struct PingCoalescer {
    public let interval: TimeInterval
    private var lastSent: [String: Date] = [:]
    private var pending: [String: NewMessagePing] = [:]

    public init(interval: TimeInterval) { self.interval = interval }

    public mutating func add(_ p: NewMessagePing) {
        if let old = pending[p.chatID], old.messageID >= p.messageID { return }
        pending[p.chatID] = p
    }

    public mutating func due(now: Date) -> [NewMessagePing] {
        var out: [NewMessagePing] = []
        for (chat, p) in pending where lastSent[chat].map({ now.timeIntervalSince($0) >= interval }) ?? true {
            out.append(p); lastSent[chat] = now
        }
        for p in out { pending[p.chatID] = nil }
        lastSent = lastSent.filter { now.timeIntervalSince($0.value) < interval }
        return out.sorted { $0.messageID < $1.messageID }
    }

    public var pendingChats: [String] { Array(pending.keys) }

    /// When the earliest waiting ping may go out, or nil if none is waiting.
    public var nextDue: Date? {
        pending.keys.map { lastSent[$0].map { $0.addingTimeInterval(interval) } ?? .distantPast }.min()
    }
}

// MARK: - Log

public struct WebhookLogEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case sent, retrying, failed, dropped }
    public var id = UUID()
    public let date: Date
    public let event: String          // "new_message" or "test"
    public let chatID: String?
    public let messageID: Int64?
    public let attempt: Int
    public let outcome: Outcome
    /// e.g. "HTTP 200" or "No internet connection". Never message content, the URL or the key.
    public let detail: String
}

/// The last 200 delivery attempts, stored as JSON Lines in Application Support (mode 0600).
public final class WebhookLog {
    private let url: URL?
    private let lock = NSLock()
    private var entries: [WebhookLogEntry] = []
    private let keep = 200
    public var onAppend: (() -> Void)?

    public init(url: URL?) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        entries = data.split(separator: 0x0A).compactMap { try? d.decode(WebhookLogEntry.self, from: Data($0)) }.suffix(keep)
    }

    public var all: [WebhookLogEntry] { lock.lock(); defer { lock.unlock() }; return entries }

    func append(_ e: WebhookLogEntry) {
        lock.lock()
        entries.append(e)
        if entries.count > keep { entries.removeFirst(entries.count - keep) }
        persist()
        lock.unlock()
        onAppend?()
    }

    public func clear() { lock.lock(); entries = []; persist(); lock.unlock(); onAppend?() }

    private func persist() {
        guard let url else { return }
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys
        let lines = entries.compactMap { try? e.encode($0) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: Data("\n".utf8)) + Data("\n".utf8)).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

// MARK: - Transport

public protocol WebhookTransport: AnyObject {
    /// Calls back with the HTTP status, or an error if there was no response.
    func post(_ request: URLRequest, completion: @escaping (Int?, Error?) -> Void)
}

/// Ephemeral session: no cookies, no cache, and redirects are refused so the key can't be
/// forwarded to another server.
public final class URLSessionWebhookTransport: NSObject, WebhookTransport, URLSessionTaskDelegate {
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 20
        c.httpCookieStorage = nil
        c.urlCache = nil
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    public override init() {}

    public func post(_ request: URLRequest, completion: @escaping (Int?, Error?) -> Void) {
        session.dataTask(with: request) { _, response, error in
            completion((response as? HTTPURLResponse)?.statusCode, error)
        }.resume()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// MARK: - Notifier

/// Watches chat.db for new messages and sends pings: incoming ones for chats with Read or Activity
/// on, and the user's own for chats with Activity on (when the config allows).
/// All state lives on one serial queue. It looks when told the database changed (`poke`), when a
/// coalesced ping falls due, and on a slow fallback timer; with pings off it never wakes.
public final class WebhookNotifier {
    public let log: WebhookLog
    private let permissions: PermissionStore
    private let openStore: () throws -> MessagesStore
    private let transport: WebhookTransport
    private let retryDelays: [TimeInterval]
    /// Messages older than this are history (e.g. an iCloud sync catching up), not news.
    private let maxAge: TimeInterval = 6 * 3600
    private let queue = DispatchQueue(label: "Veil.webhook")

    private var store: MessagesStore?
    private var config: WebhookConfig?
    private var lastSeen: Int64?
    private var coalescer: PingCoalescer
    private var timer: DispatchSourceTimer?
    private var fallback: TimeInterval = 30
    /// A new message's chat link wasn't written yet; look again shortly.
    private var lookAgainSoon = false

    public init(permissions: PermissionStore, openStore: @escaping () throws -> MessagesStore, log: WebhookLog,
                transport: WebhookTransport = URLSessionWebhookTransport(),
                interval: TimeInterval = 60, retryDelays: [TimeInterval] = [5, 30, 120]) {
        self.permissions = permissions; self.openStore = openStore; self.log = log
        self.transport = transport; self.retryDelays = retryDelays
        coalescer = PingCoalescer(interval: interval)
    }

    /// nil turns pings off and forgets anything pending. Turning them on starts from "now",
    /// so the backlog is never announced.
    public func configure(_ c: WebhookConfig?) {
        queue.sync {
            if c == nil || config == nil { lastSeen = nil; coalescer = PingCoalescer(interval: coalescer.interval) }
            config = c
        }
        // Take the starting point right away, so a message arriving before the next look is still news.
        queue.async { [self] in if timer != nil { step() } }
    }

    /// `fallback`: how often to look without being told of a change, in case a file event was missed.
    public func start(fallback seconds: TimeInterval = 30) {
        queue.sync {
            guard timer == nil else { return }
            fallback = seconds
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.setEventHandler { [weak self] in self?.step() }
            t.schedule(deadline: .distantFuture)
            t.resume(); timer = t
        }
        queue.async { [self] in step() }
    }

    public func stop() { queue.sync { timer?.cancel(); timer = nil } }

    /// The database may have changed: look now (if pings are on).
    public func poke() { queue.async { [self] in if timer != nil, config != nil { step() } } }

    /// One polling step. The timer calls this; tests call it directly.
    public func tick(now: Date = Date()) { queue.sync { poll(now: now) } }

    /// Looks, then sets the next wake-up: when a held-back ping falls due, soon if a message was
    /// half-written, otherwise the fallback. Nothing at all while pings are off.
    private func step() {
        guard let timer else { return }
        let now = Date()
        let read = poll(now: now)
        guard config != nil else { timer.schedule(deadline: .distantFuture); return }
        var wait = fallback
        // After a failed read (e.g. no Full Disk Access), just wait for the fallback.
        if read, lookAgainSoon { wait = min(wait, 2) }
        if read, let due = coalescer.nextDue { wait = min(wait, max(0.05, due.timeIntervalSince(now))) }
        timer.schedule(deadline: .now() + wait, leeway: wait < fallback ? .milliseconds(250) : .seconds(5))
    }

    /// Returns false if the database couldn't be read.
    @discardableResult
    private func poll(now: Date) -> Bool {
        guard config != nil else { return true }
        lookAgainSoon = false
        do {
            let store = try self.store ?? openStore()
            self.store = store
            guard let since = lastSeen else { lastSeen = try store.maxMessageRowID(); return true }
            let rows = try store.messages(afterRowID: since, limit: 500)
            var newest = since
            var chatNames: [Int64: String]?
            for r in rows {
                guard let chatRow = r.chatRowID else {
                    // Messages writes the chat link right after the message; wait for it briefly.
                    if now.timeIntervalSince(r.date) < 30 { lookAgainSoon = true; break }
                    newest = max(newest, r.id); continue
                }
                newest = max(newest, r.id)
                guard r.isPlainMessage, now.timeIntervalSince(r.date) < maxAge else { continue }
                if r.isFromMe && config?.pingReplies != true { continue }
                if chatNames == nil { chatNames = try store.chatIdentifiers() }
                // Policy check: only chats the user has opened. Locked, hidden and paused chats are
                // dropped here, before anything is queued.
                guard let chat = chatNames?[chatRow], allowed(chat, fromMe: r.isFromMe, date: r.date, now: now) else { continue }
                coalescer.add(NewMessagePing(chatID: chat, messageID: r.id, receivedAt: r.date, fromMe: r.isFromMe))
            }
            lastSeen = newest
        } catch {
            store = nil   // e.g. Full Disk Access missing or Messages busy; try again next tick
            return false
        }
        for p in coalescer.due(now: now) { deliver(p, attempt: 1) }
        return true
    }

    /// Incoming: Read or Activity. The user's own messages: Activity only, and only if the config allows.
    /// A message outside the chat's history window (e.g. one from before "Only after I shared this chat")
    /// is never announced. An ended time limit counts as locked.
    private func allowed(_ chat: String, fromMe: Bool, date: Date, now: Date) -> Bool {
        let state = permissions.state
        let a = state.access(chat, now: now)
        if let cutoff = state.historyCutoff(chat, now: now), date < cutoff { return false }
        if fromMe { return a.activity && !a.hidden && config?.pingReplies == true }
        return a.seesActivity
    }

    // MARK: Delivery

    private func deliver(_ p: NewMessagePing, attempt: Int) {
        guard let cfg = config else { return }
        // Checked again at send time, so a chat locked during the quiet period or a retry is never pinged.
        guard allowed(p.chatID, fromMe: p.fromMe, date: p.receivedAt, now: Date()) else {
            log.append(entry("new_message", p, attempt, .dropped, "Chat was locked before the ping went out"))
            return
        }
        let body = Payload(event: "new_message", chat_id: p.chatID, message_id: p.messageID,
                           received_at: Self.iso(p.receivedAt), direction: p.fromMe ? "from_me" : "incoming", sent_at: nil)
        post(cfg, body) { [self] status, error in
            let (outcome, detail, retry) = classify(status, error)
            if outcome == .sent || !retry {
                log.append(entry("new_message", p, attempt, outcome, detail))
            } else if attempt <= retryDelays.count {
                let wait = retryDelays[attempt - 1]
                log.append(entry("new_message", p, attempt, .retrying, "\(detail), trying again in \(Int(wait.rounded()))s"))
                queue.asyncAfter(deadline: .now() + wait) { self.deliver(p, attempt: attempt + 1) }
            } else {
                log.append(entry("new_message", p, attempt, .dropped, "Gave up after \(attempt) tries: \(detail)"))
            }
        }
    }

    /// One attempt, no retries. Works whether or not pings are switched on.
    public func sendTest(_ cfg: WebhookConfig, done: @escaping (WebhookLogEntry) -> Void) {
        post(cfg, Payload(event: "test", chat_id: nil, message_id: nil, received_at: nil, direction: nil, sent_at: Self.iso(Date()))) { [self] status, error in
            let (outcome, detail, _) = classify(status, error)
            let e = WebhookLogEntry(date: Date(), event: "test", chatID: nil, messageID: nil, attempt: 1,
                                    outcome: outcome == .sent ? .sent : .failed, detail: detail)
            log.append(e)
            done(e)
        }
    }

    private struct Payload: Encodable {
        let event: String
        let chat_id: String?
        let message_id: Int64?
        let received_at: String?
        let direction: String?
        let sent_at: String?
    }

    /// Calls back on the notifier's queue.
    private func post(_ cfg: WebhookConfig, _ body: Payload, done: @escaping (Int?, Error?) -> Void) {
        var req = URLRequest(url: cfg.url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Veil", forHTTPHeaderField: "User-Agent")
        req.setValue(cfg.headerValue, forHTTPHeaderField: cfg.headerName)
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        req.httpBody = try? enc.encode(body)
        transport.post(req) { [queue] status, error in queue.async { done(status, error) } }
    }

    /// (outcome, plain-language detail, worth retrying)
    private func classify(_ status: Int?, _ error: Error?) -> (WebhookLogEntry.Outcome, String, Bool) {
        if let s = status {
            switch s {
            case 200..<300: return (.sent, "HTTP \(s)", false)
            case 401, 403: return (.failed, "HTTP \(s): the webhook didn't accept the key", false)
            case 300..<400: return (.failed, "HTTP \(s): redirects aren't followed", false)
            case 408, 425, 429, 500..<600: return (.failed, "HTTP \(s)", true)
            default: return (.failed, "HTTP \(s)", false)
            }
        }
        let code = (error as? URLError)?.code
        let detail: String
        switch code {
        case .notConnectedToInternet?, .networkConnectionLost?: detail = "No internet connection"
        case .timedOut?: detail = "Timed out"
        case .cannotFindHost?, .dnsLookupFailed?: detail = "Couldn't find the server"
        case .cannotConnectToHost?: detail = "Couldn't connect to the server"
        case .secureConnectionFailed?, .serverCertificateUntrusted?, .serverCertificateHasBadDate?: detail = "Secure connection failed"
        default: detail = "Network error \(code.map { String($0.rawValue) } ?? "")".trimmingCharacters(in: .whitespaces)
        }
        return (.failed, detail, true)
    }

    private func entry(_ event: String, _ p: NewMessagePing, _ attempt: Int, _ o: WebhookLogEntry.Outcome, _ d: String) -> WebhookLogEntry {
        WebhookLogEntry(date: Date(), event: event, chatID: p.chatID, messageID: p.messageID, attempt: attempt, outcome: o, detail: d)
    }

    static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}

// MARK: - Database queries used only by the notifier

struct NewRow { let id: Int64; let chatRowID: Int64?; let date: Date; let isFromMe: Bool; let isPlainMessage: Bool }

extension MessagesStore {
    func maxMessageRowID() throws -> Int64 {
        try db.query("SELECT COALESCE(MAX(ROWID), 0) AS m FROM message").first?.int("m") ?? 0
    }

    /// Message rows newer than `afterRowID`, oldest first. Ids and flags only, never text.
    func messages(afterRowID: Int64, limit: Int) throws -> [NewRow] {
        try db.query("""
            SELECT m.ROWID AS id, m.date, m.is_from_me, COALESCE(m.associated_message_type, 0) AS assoc,
                   COALESCE(m.item_type, 0) AS item, cmj.chat_id
            FROM message m LEFT JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE m.ROWID > ? ORDER BY m.ROWID LIMIT ?
            """, [.int(afterRowID), .int(Int64(limit))]).map {
            NewRow(id: $0.int("id") ?? 0, chatRowID: $0.int("chat_id"), date: appleDate($0.int("date") ?? 0),
                   isFromMe: ($0.int("is_from_me") ?? 0) != 0,
                   isPlainMessage: ($0.int("assoc") ?? 0) == 0 && ($0.int("item") ?? 0) == 0)
        }
    }

    func chatIdentifiers() throws -> [Int64: String] {
        var out: [Int64: String] = [:]
        for r in try db.query("SELECT ROWID AS id, chat_identifier FROM chat") {
            if let id = r.int("id"), let s = r.str("chat_identifier") { out[id] = s }
        }
        return out
    }
}

// MARK: - Keychain

/// One secret string. The real one is the Keychain; tests use `MemoryStringStore`.
public protocol StringSecretStore: AnyObject {
    /// nil when nothing is stored; throws when it can't be read (locked, or needs approval).
    func load() throws -> String?
    func write(_ value: String) throws
}

/// A single string in the login Keychain. Used for the webhook key.
public final class KeychainString: StringSecretStore {
    private let service: String
    private let allowUI: Bool
    /// `allowUI: false` never shows a Keychain prompt: a read that would need the user's approval fails instead.
    public init(service: String, allowUI: Bool = true) { self.service = service; self.allowUI = allowUI }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "key"]
    }

    public func read() -> String? { (try? load()) ?? nil }

    /// Whether the item exists. Reads attributes only, so it never needs the user's approval.
    public func exists() -> Bool { KeychainPrompts.itemExists(query) }

    public func load() throws -> String? {
        var q = query; q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = KeychainPrompts.copyMatching(q, allowUI: allowUI, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let d = out as? Data else { throw KeychainSecretStore.KeychainError(status: status) }
        return String(data: d, encoding: .utf8)
    }

    public func write(_ value: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data; add[kSecAttrLabel as String] = service
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw KeychainSecretStore.KeychainError(status: s) }
        } else if status != errSecSuccess { throw KeychainSecretStore.KeychainError(status: status) }
    }

    public func delete() { SecItemDelete(query as CFDictionary) }
}

/// In-memory string secret for tests.
public final class MemoryStringStore: StringSecretStore {
    public var value: String?
    public init(_ value: String? = nil) { self.value = value }
    public func load() throws -> String? { value }
    public func write(_ value: String) throws { self.value = value }
}
