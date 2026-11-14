import Foundation

// "Activity only": when messages came and went in a chat, never what they said.
//
// These queries are deliberately separate from the message queries in MessagesStore. Their
// SELECT lists name only ids, dates, direction and the sender's handle. They never read
// text, attributedBody, subject, reactions or attachment columns, so content can't reach
// the assistant through this path even by mistake.

/// One message, minus everything it said.
public struct ActivityItem: Equatable, Sendable {
    public let id: Int64
    public let date: Date
    public let isFromMe: Bool
    public let senderHandle: String?
}

/// Latest incoming message and latest message from the user in a chat.
public struct ActivitySummary: Equatable, Sendable {
    public let lastIncoming: Date?
    public let lastFromMe: Date?
    /// True when someone wrote after the user's last message (or the user never wrote).
    public var awaitingReply: Bool {
        guard let i = lastIncoming else { return false }
        return lastFromMe.map { i > $0 } ?? true
    }
}

extension MessagesStore {
    /// Real messages only (no tapbacks or system events), newest first. Scoped to the given chat rows.
    /// `notBefore` is the chat's history window; `since` can narrow it further but never widen it.
    func activity(inChats chats: [Int64], since: Date? = nil, beforeID: Int64? = nil, limit: Int, notBefore: Date? = nil) throws -> [ActivityItem] {
        guard !chats.isEmpty else { return [] }
        let since = [since, notBefore].compactMap { $0 }.max()
        let inList = Array(repeating: "?", count: chats.count).joined(separator: ",")
        var params: [SQLiteDB.Value] = chats.map { .int($0) }
        var extra = ""
        if let since { extra += " AND m.date >= ?"; params.append(.int(appleTimestamp(since))) }
        if let b = beforeID {
            // Same cursor rule as read_chat: the cursor must belong to these chats.
            let (window, windowParams) = Self.window(notBefore)
            guard let d = try db.query("""
                SELECT m.date FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
                WHERE m.ROWID = ? AND cmj.chat_id IN (\(inList)) \(window) LIMIT 1
                """, [.int(b)] + chats.map { .int($0) } + windowParams).first?.int("date") else { return [] }
            extra += " AND (m.date < ? OR (m.date = ? AND m.ROWID < ?))"
            params += [.int(d), .int(d), .int(b)]
        }
        params.append(.int(Int64(limit)))
        return try db.query("""
            SELECT m.ROWID AS id, m.date AS date, m.is_from_me AS from_me, h.id AS sender
            FROM message m
            JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE cmj.chat_id IN (\(inList)) \(extra)
              AND COALESCE(m.associated_message_type, 0) = 0 AND COALESCE(m.item_type, 0) = 0
            GROUP BY m.ROWID ORDER BY m.date DESC, m.ROWID DESC LIMIT ?
            """, params).map {
            ActivityItem(id: $0.int("id") ?? 0, date: appleDate($0.int("date") ?? 0),
                         isFromMe: ($0.int("from_me") ?? 0) != 0, senderHandle: $0.str("sender"))
        }
    }

    /// With `notBefore` (the chat's history window), messages older than it don't count, as if they didn't exist.
    func activitySummary(inChats chats: [Int64], notBefore: Date? = nil) throws -> ActivitySummary {
        guard !chats.isEmpty else { return ActivitySummary(lastIncoming: nil, lastFromMe: nil) }
        let inList = Array(repeating: "?", count: chats.count).joined(separator: ",")
        let (window, windowParams) = Self.window(notBefore)
        let r = try db.query("""
            SELECT MAX(CASE WHEN m.is_from_me = 0 THEN m.date END) AS last_in,
                   MAX(CASE WHEN m.is_from_me = 1 THEN m.date END) AS last_out
            FROM message m JOIN chat_message_join cmj ON cmj.message_id = m.ROWID
            WHERE cmj.chat_id IN (\(inList)) \(window)
              AND COALESCE(m.associated_message_type, 0) = 0 AND COALESCE(m.item_type, 0) = 0
            """, chats.map { .int($0) } + windowParams).first
        return ActivitySummary(lastIncoming: r?.int("last_in").map(appleDate), lastFromMe: r?.int("last_out").map(appleDate))
    }
}

/// Parses `since` for chat_activity: full ISO 8601 (with or without fractional seconds) or a plain date.
func parseSince(_ s: String) -> Date? {
    let t = s.trimmingCharacters(in: .whitespaces)
    let f = ISO8601DateFormatter()
    if let d = f.date(from: t) { return d }
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: t) { return d }
    f.formatOptions = [.withFullDate]; f.timeZone = .current
    return f.date(from: t)
}
