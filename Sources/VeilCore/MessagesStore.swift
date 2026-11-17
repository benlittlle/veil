import Foundation

// MARK: - Plain data types (no policy here)

public struct Participant: Equatable, Hashable, Sendable {
    public let handle: String        // phone number or email, as stored by Messages
    public var name: String?         // resolved from Contacts, if known
    public var label: String { name ?? handle }
}

/// One conversation as the user sees it in Messages. Messages may store several `chat`
/// rows (e.g. iMessage + SMS) for the same conversation; we group them by identifier.
public struct Conversation: Equatable, Sendable, Identifiable {
    public let id: String            // chat_identifier: a phone/email for 1:1, "chat…" for groups
    public let chatRowIDs: [Int64]
    public let chatGUIDs: [String]   // used only for sending via Messages
    public let groupName: String?
    public let isGroup: Bool
    public var participants: [Participant]
    public let lastActivity: Date?

    public var displayName: String {
        if let g = groupName, !g.isEmpty { return g }
        if !isGroup { return participants.first?.label ?? id }
        let names = participants.map { $0.name ?? $0.handle }
        if names.count <= 3 { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " & \(names.count - 2) others"
    }

    /// The name as Veil's own prompts, notifications and Activity show it (see `DisplayLabel`).
    public var safeName: String { DisplayLabel.clean(displayName, max: 60) }
}

public struct AttachmentInfo: Equatable, Sendable {
    public let id: Int64
    public let path: String?
    public let mimeType: String?
    public let name: String?
    public let bytes: Int64
}

public struct Message: Equatable, Sendable {
    public let id: Int64
    public let guid: String
    public let chatRowID: Int64
    public let date: Date
    public let isFromMe: Bool
    public let senderHandle: String?
    public let text: String?
    public let replyToGUID: String?
    public let attachments: [AttachmentInfo]
}

// MARK: - Store

/// Reads ~/Library/Messages/chat.db. Opened read-only. Every query that returns
/// message content is scoped to an explicit list of chat row ids chosen by the Gate.
public final class MessagesStore {
    let db: SQLiteDB
    public let attachmentsRoot: URL
    private let home: String

    public init(databasePath: String, attachmentsRoot: URL, home: String = NSHomeDirectory()) throws {
        db = try SQLiteDB(path: databasePath, readOnly: true)
        self.attachmentsRoot = attachmentsRoot
        self.home = home
        // Fails fast if the file is unreadable (e.g. missing Full Disk Access).
        try db.query("SELECT 1 FROM chat LIMIT 1")
    }

    /// Changes whenever another connection (Messages) commits to the database. Reads no tables.
    public func changeToken() throws -> Int64 {
        try db.query("PRAGMA data_version").first?.int("data_version") ?? 0
    }

    public func conversations(contacts: ContactResolver) throws -> [Conversation] {
        let chats = try db.query("""
            SELECT c.ROWID AS id, c.guid, c.chat_identifier, c.display_name, c.style,
                   (SELECT MAX(cmj.message_date) FROM chat_message_join cmj WHERE cmj.chat_id = c.ROWID) AS last
            FROM chat c
            """)
        let members = try db.query("""
            SELECT chj.chat_id, h.id AS handle FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id
            """)
        var handlesByChat: [Int64: [String]] = [:]
        for m in members { if let c = m.int("chat_id"), let h = m.str("handle") { handlesByChat[c, default: []].append(h) } }

        var grouped: [String: [[String: SQLiteDB.Value]]] = [:]
        var order: [String] = []
        for c in chats {
            guard let ident = c.str("chat_identifier"), !ident.isEmpty else { continue }
            if grouped[ident] == nil { order.append(ident) }
            grouped[ident, default: []].append(c)
        }
        return order.compactMap { ident in
            guard let rows = grouped[ident] else { return nil }
            let rowIDs = rows.compactMap { $0.int("id") }
            var handles: [String] = []
            for r in rowIDs { for h in handlesByChat[r] ?? [] where !handles.contains(h) { handles.append(h) } }
            let isGroup = rows.contains { $0.int("style") == 43 } || handles.count > 1
            if handles.isEmpty && !isGroup { handles = [ident] }
            let last = rows.compactMap { $0.int("last") }.max().map(appleDate)
            // Prefer the iMessage chat row for sending.
            let guids = rows.compactMap { $0.str("guid") }.sorted { a, _ in a.hasPrefix("iMessage") }
            return Conversation(
                id: ident, chatRowIDs: rowIDs, chatGUIDs: guids,
                groupName: rows.compactMap { $0.str("display_name") }.first { !$0.isEmpty },
                isGroup: isGroup,
                participants: handles.map { Participant(handle: $0, name: contacts.name(for: $0)) },
                lastActivity: last)
        }
    }

    /// Real messages only (no reactions, no "X named the conversation" events), newest first.
    /// `notBefore` is the chat's history window: nothing older comes back, as if it didn't exist.
    public func messages(inChats chats: [Int64], beforeID: Int64? = nil, limit: Int, notBefore: Date? = nil) throws -> [Message] {
        guard !chats.isEmpty else { return [] }
        let (window, windowParams) = Self.window(notBefore)
        var params: [SQLiteDB.Value] = chats.map { .int($0) } + windowParams
        var cursor = ""
        if let b = beforeID {
            // Page by (date, ROWID): synced messages can have ROWIDs out of date order.
            // The cursor message must belong to these chats (and their window), so ids can't be probed.
            guard let d = try db.query("""
                SELECT m.date FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE m.ROWID = ? AND cmj.chat_id IN (\(placeholders(chats.count))) \(window) LIMIT 1
                """, [.int(b)] + chats.map { .int($0) } + windowParams).first?.int("date") else { return [] }
            cursor = "AND (m.date < ? OR (m.date = ? AND m.ROWID < ?))"
            params += [.int(d), .int(d), .int(b)]
        }
        params.append(.int(Int64(limit)))
        return try hydrate(db.query("""
            SELECT \(Self.messageColumns) FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id IN (\(placeholders(chats.count))) \(window) \(cursor)
              AND m.associated_message_type = 0 AND m.item_type = 0
            GROUP BY m.ROWID ORDER BY m.date DESC, m.ROWID DESC LIMIT ?
            """, params))
    }

    /// `AND m.date >= ?` for a history window, or nothing.
    static func window(_ notBefore: Date?) -> (String, [SQLiteDB.Value]) {
        guard let d = notBefore else { return ("", []) }
        return ("AND m.date >= ?", [.int(appleTimestamp(d))])
    }

    /// Look up a message by guid, but only inside the given chats and their history window (used for reply quotes).
    public func message(guid: String, inChats chats: [Int64], notBefore: Date? = nil) throws -> Message? {
        guard !chats.isEmpty else { return nil }
        let (window, windowParams) = Self.window(notBefore)
        return try hydrate(db.query("""
            SELECT \(Self.messageColumns) FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.guid = ? AND cmj.chat_id IN (\(placeholders(chats.count))) \(window) LIMIT 1
            """, [.text(guid)] + chats.map { .int($0) } + windowParams)).first
    }

    /// Chat rows to search, with the history window that applies to them.
    public struct SearchScope: Sendable {
        public let rows: [Int64]
        public let notBefore: Date?
        public init(rows: [Int64], notBefore: Date?) { self.rows = rows; self.notBefore = notBefore }
    }

    /// Text search, scoped to the given chats. Newer macOS stores text only in
    /// `attributedBody`, so we prefilter in SQL and confirm on decoded text.
    public func search(_ query: String, inChats chats: [Int64], limit: Int) throws -> [Message] {
        try search(query, in: [SearchScope(rows: chats, notBefore: nil)], limit: limit)
    }

    /// Text search over several chats, each with its own history window: a match older than its
    /// chat's window is never considered.
    public func search(_ query: String, in scopes: [SearchScope], limit: Int) throws -> [Message] {
        let scopes = scopes.filter { !$0.rows.isEmpty }
        let chats = scopes.flatMap(\.rows)
        guard !chats.isEmpty, !query.isEmpty else { return [] }
        // Rows without a window share one IN list; each windowed chat gets its own date bound.
        var clauses: [String] = []
        var params: [SQLiteDB.Value] = []
        let open = scopes.filter { $0.notBefore == nil }.flatMap(\.rows)
        if !open.isEmpty { clauses.append("+cmj.chat_id IN (\(placeholders(open.count)))"); params += open.map { .int($0) } }
        for sc in scopes { if let d = sc.notBefore {
            clauses.append("(+cmj.chat_id IN (\(placeholders(sc.rows.count))) AND m.date >= ?)")
            params += sc.rows.map { .int($0) } + [.int(appleTimestamp(d))]
        } }
        // SQLite's LIKE only folds ASCII case, so it's used as a prefilter for ASCII queries only.
        // Rows whose text lives in attributedBody are always decoded and checked here.
        var filter = ""
        if query.allSatisfy(\.isASCII) {
            let like = "%" + query.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            filter = "AND (m.text LIKE ? ESCAPE '\\' OR ((m.text IS NULL OR m.text = '') AND m.attributedBody IS NOT NULL))"
            params.append(.text(like))
        }
        var hits: [Int64] = []
        // EXISTS (with `+` to steer SQLite onto the message_id index) scans messages newest-first
        // and stops as soon as enough hits are found, even with thousands of chats in scope.
        try db.each("""
            SELECT m.ROWID AS id, m.text, m.attributedBody FROM message m
            WHERE EXISTS (SELECT 1 FROM chat_message_join cmj
                          WHERE cmj.message_id = m.ROWID AND (\(clauses.joined(separator: " OR "))))
              AND m.associated_message_type = 0 AND m.item_type = 0 \(filter)
            ORDER BY m.date DESC
            """, params) { r in
            var text = r.str("text") ?? ""
            if text.isEmpty, let b = r.blob("attributedBody") { text = AttributedBody.text(from: b) ?? "" }
            if text.localizedCaseInsensitiveContains(query), let id = r.int("id") { hits.append(id) }
            return hits.count < limit
        }
        guard !hits.isEmpty else { return [] }
        let found = try hydrate(db.query("""
            SELECT \(Self.messageColumns) FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE m.ROWID IN (\(placeholders(hits.count))) AND cmj.chat_id IN (\(placeholders(chats.count)))
            GROUP BY m.ROWID ORDER BY m.date DESC
            """, hits.map { .int($0) } + chats.map { .int($0) }))
        return found
    }

    /// Latest real message per chat row, for "waiting on reply".
    public func latestMessage(inChats chats: [Int64], notBefore: Date? = nil) throws -> Message? {
        try messages(inChats: chats, limit: 1, notBefore: notBefore).first
    }

    /// Attachments in the given chats, newest first. With `notBefore`, only those on messages inside the window.
    public func attachments(inChats chats: [Int64], beforeID: Int64? = nil, limit: Int, notBefore: Date? = nil) throws -> [(AttachmentInfo, Message)] {
        guard !chats.isEmpty else { return [] }
        let (window, windowParams) = Self.window(notBefore)
        var params: [SQLiteDB.Value] = chats.map { .int($0) } + windowParams
        var cursor = ""
        if let b = beforeID { cursor = "AND maj.attachment_id < ?"; params.append(.int(b)) }
        params.append(.int(Int64(limit)))
        let rows = try db.query("""
            SELECT DISTINCT maj.attachment_id AS aid, m.ROWID AS mid FROM message_attachment_join maj
            JOIN message m ON m.ROWID = maj.message_id
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id IN (\(placeholders(chats.count))) \(window) \(cursor)
            ORDER BY maj.attachment_id DESC LIMIT ?
            """, params)
        return try rows.compactMap { r in
            guard let aid = r.int("aid"), let mid = r.int("mid"),
                  let a = try attachment(id: aid), let m = try messageByID(mid),
                  notBefore.map({ m.date >= $0 }) ?? true else { return nil }
            return (a, m)
        }
    }

    public func attachment(id: Int64) throws -> AttachmentInfo? {
        try db.query("SELECT ROWID, filename, mime_type, transfer_name, total_bytes FROM attachment WHERE ROWID = ?", [.int(id)])
            .first.map(attachmentInfo)
    }

    /// Every chat row that a given attachment is reachable from. The Gate requires all of them to be allowed.
    public func chatRowIDs(forAttachment id: Int64) throws -> [Int64] {
        try db.query("""
            SELECT DISTINCT cmj.chat_id FROM message_attachment_join maj
            JOIN chat_message_join cmj ON cmj.message_id = maj.message_id
            WHERE maj.attachment_id = ?
            """, [.int(id)]).compactMap { $0.int("chat_id") }
    }

    /// The messages (inside the given chats and their history window) that carry an attachment. Used by the content filter.
    public func messages(forAttachment id: Int64, inChats chats: [Int64], notBefore: Date? = nil) throws -> [Message] {
        guard !chats.isEmpty else { return [] }
        let (window, windowParams) = Self.window(notBefore)
        return try hydrate(db.query("""
            SELECT \(Self.messageColumns) FROM message m
            JOIN message_attachment_join maj ON maj.message_id = m.ROWID
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE maj.attachment_id = ? AND cmj.chat_id IN (\(placeholders(chats.count))) \(window)
            GROUP BY m.ROWID
            """, [.int(id)] + chats.map { .int($0) } + windowParams))
    }

    /// For each chat row an attachment appears in, the time of the newest message there that carries it.
    /// The gate uses this so every chat's history window must include the attachment.
    public func attachmentLatestDates(_ id: Int64) throws -> [Int64: Date] {
        var out: [Int64: Date] = [:]
        for r in try db.query("""
            SELECT cmj.chat_id AS chat, MAX(m.date) AS d FROM message_attachment_join maj
            JOIN message m ON m.ROWID = maj.message_id
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE maj.attachment_id = ? GROUP BY cmj.chat_id
            """, [.int(id)]) {
            if let c = r.int("chat"), let d = r.int("d") { out[c] = appleDate(d) }
        }
        return out
    }

    /// Resolves an attachment to a file that is guaranteed to live inside the attachments folder.
    public func safeFileURL(for a: AttachmentInfo) -> URL? {
        guard var p = a.path, !p.isEmpty else { return nil }
        if p.hasPrefix("~") { p = home + p.dropFirst() }
        let file = URL(fileURLWithPath: p).standardizedFileURL.resolvingSymlinksInPath()
        let root = attachmentsRoot.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard file.path.hasPrefix(root) else { return nil }
        return file
    }

    // MARK: helpers

    private static let messageColumns = """
        m.ROWID AS id, m.guid, m.text, m.attributedBody, m.date, m.is_from_me, m.thread_originator_guid,
        m.cache_has_attachments, h.id AS sender, cmj.chat_id
        """

    private func messageByID(_ id: Int64) throws -> Message? {
        try hydrate(db.query("""
            SELECT \(Self.messageColumns) FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id WHERE m.ROWID = ? LIMIT 1
            """, [.int(id)])).first
    }

    private func hydrate(_ rows: [[String: SQLiteDB.Value]]) throws -> [Message] {
        try rows.map { r in
            let id = r.int("id") ?? 0
            var atts: [AttachmentInfo] = []
            if (r.int("cache_has_attachments") ?? 0) != 0 {
                atts = try db.query("""
                    SELECT a.ROWID, a.filename, a.mime_type, a.transfer_name, a.total_bytes FROM attachment a
                    JOIN message_attachment_join maj ON maj.attachment_id = a.ROWID WHERE maj.message_id = ?
                    """, [.int(id)]).map(attachmentInfo)
            }
            var text = r.str("text")
            if text == nil || text!.isEmpty, let body = r.blob("attributedBody") { text = AttributedBody.text(from: body) }
            // U+FFFC is the inline placeholder Messages uses for attachments.
            text = text?.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            return Message(
                id: id, guid: r.str("guid") ?? "", chatRowID: r.int("chat_id") ?? 0,
                date: appleDate(r.int("date") ?? 0), isFromMe: (r.int("is_from_me") ?? 0) != 0,
                senderHandle: r.str("sender"), text: (text?.isEmpty ?? true) ? nil : text,
                replyToGUID: r.str("thread_originator_guid").flatMap { $0.isEmpty ? nil : $0 },
                attachments: atts)
        }
    }

    private func attachmentInfo(_ r: [String: SQLiteDB.Value]) -> AttachmentInfo {
        AttachmentInfo(id: r.int("ROWID") ?? 0, path: r.str("filename"), mimeType: r.str("mime_type"),
                       name: r.str("transfer_name"), bytes: r.int("total_bytes") ?? 0)
    }

    private func placeholders(_ n: Int) -> String { Array(repeating: "?", count: n).joined(separator: ",") }
}

/// Messages stores dates as seconds (older) or nanoseconds (newer) since 2001-01-01.
func appleDate(_ raw: Int64) -> Date {
    let seconds = raw > 1_000_000_000_000 ? Double(raw) / 1_000_000_000 : Double(raw)
    return Date(timeIntervalSinceReferenceDate: seconds)
}

func appleTimestamp(_ d: Date) -> Int64 { Int64(d.timeIntervalSinceReferenceDate * 1_000_000_000) }

/// Extracts the plain string from a Messages `attributedBody` (an NSArchiver typedstream)
/// without deserializing any objects.
enum AttributedBody {
    static func text(from data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard let start = find(marker, in: bytes) else { return nil }
        var i = start + marker.count
        // Skip the class-chain bytes up to the '+' that introduces the string.
        guard let plus = bytes[i..<min(i + 16, bytes.count)].firstIndex(of: 0x2B) else { return nil }
        i = plus + 1
        guard i < bytes.count else { return nil }
        var length = 0
        switch bytes[i] {
        case 0x81:
            guard i + 2 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8; i += 3
        case 0x82:
            guard i + 4 < bytes.count else { return nil }
            length = Int(bytes[i + 1]) | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3]) << 16 | Int(bytes[i + 4]) << 24; i += 5
        default:
            length = Int(bytes[i]); i += 1
        }
        guard length > 0, i + length <= bytes.count else { return nil }
        return String(bytes: bytes[i..<(i + length)], encoding: .utf8)
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] {
            if Array(hay[i..<(i + needle.count)]) == needle { return i }
        }
        return nil
    }
}
