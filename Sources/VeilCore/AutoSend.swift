import Foundation

/// One message Veil sent without asking, because the user turned on auto-send for that chat.
public struct AutoSendRecord: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case sent, failed }
    public var id = UUID()
    public let date: Date
    public let chatID: String
    public let chatName: String
    public let text: String
    public let client: String
    public let outcome: Outcome
    public let detail: String?
}

/// The user's record of auto-sent messages, including their text. Stored as JSON Lines in
/// Application Support (mode 0600), last 500 kept. Not reachable from MCP.
public final class AutoSendHistory {
    private let url: URL?
    private let lock = NSLock()
    private var entries: [AutoSendRecord] = []
    private let keep = 500
    public var onChange: (() -> Void)?

    public init(url: URL?) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url) else { return }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        entries = data.split(separator: 0x0A).compactMap { try? d.decode(AutoSendRecord.self, from: Data($0)) }.suffix(keep)
    }

    public var all: [AutoSendRecord] { lock.lock(); defer { lock.unlock() }; return entries }

    func append(_ r: AutoSendRecord) {
        lock.lock()
        entries.append(r)
        if entries.count > keep { entries.removeFirst(entries.count - keep) }
        persist()
        lock.unlock()
        onChange?()
    }

    public func clear() { lock.lock(); entries = []; persist(); lock.unlock(); onChange?() }

    private func persist() {
        guard let url else { return }
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .sortedKeys
        let lines = entries.compactMap { try? e.encode($0) }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (lines.joined(separator: Data("\n".utf8)) + Data("\n".utf8)).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Sliding-window counter per chat. Seeded from history so a restart doesn't reset it,
/// and unaffected by clearing the history.
struct AutoSendLimiter {
    private var times: [String: [Date]] = [:]

    init(history: [AutoSendRecord]) {
        for r in history { times[r.chatID, default: []].append(r.date) }
    }

    /// Claims a slot if the chat is under its limit.
    mutating func reserve(_ chat: String, _ limit: AutoSendLimit, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(max(1, limit.minutes)) * 60)
        var t = (times[chat] ?? []).filter { $0 > cutoff }
        defer { times[chat] = t }
        guard t.count < limit.count else { return false }
        t.append(now)
        return true
    }
}
