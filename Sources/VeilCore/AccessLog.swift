import Foundation

public struct LogEntry: Codable, Identifiable, Equatable, Sendable {
    public enum Outcome: String, Codable, Sendable { case allowed, denied, failed }
    public var id = UUID()
    public let date: Date
    public let client: String
    public let tool: String
    public let chatID: String?
    public let chatName: String?
    public let outcome: Outcome
    /// High-level description of what was returned. Never message content.
    public let summary: String
}

/// Record of every request that comes through MCP. Kept as JSON Lines in Application
/// Support (rotated so it never grows past a few MB) and mirrored in memory for the app.
public final class AccessLog {
    private let url: URL?
    private let lock = NSLock()
    private var entries: [LogEntry] = []
    private let keep = 2000
    private let maxBytes = 4_000_000
    public var onAppend: ((LogEntry) -> Void)?

    public init(url: URL?) {
        self.url = url
        guard let url, let h = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? h.close() }
        // Only read the tail, so a large file can't slow down launch.
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0)
        let data = (try? h.readToEnd()) ?? Data()
        entries = Self.decode(data).suffix(keep)
    }

    public var all: [LogEntry] { lock.lock(); defer { lock.unlock() }; return entries }

    public func append(_ e: LogEntry) {
        lock.lock()
        entries.append(e)
        if entries.count > keep * 2 { entries.removeFirst(entries.count - keep) }
        if let url { write(e, to: url) }
        lock.unlock()
        onAppend?(e)
    }

    /// Deletes the whole log, on disk and in memory.
    public func clear() {
        lock.lock(); entries = []; if let url { try? FileManager.default.removeItem(at: url) }; lock.unlock()
    }

    private func write(_ e: LogEntry, to url: URL) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .sortedKeys
        guard let line = try? enc.encode(e) else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        // Rotate: when the file passes the limit, rewrite it with recent entries filling about half
        // the limit, so rotation happens rarely rather than on every append.
        if let size = (try? fm.attributesOfItem(atPath: url.path)[.size]) as? Int, size > maxBytes {
            var recent: [Data] = [], total = 0
            for entry in entries.reversed() {
                guard let d = try? enc.encode(entry), total + d.count < maxBytes / 2 else { break }
                recent.insert(d, at: 0); total += d.count + 1
            }
            try? Data(recent.joined(separator: Data("\n".utf8)) + Data("\n".utf8)).write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return
        }
        // `write(contentsOf:)` throws instead of raising, so a full disk can't crash the app.
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line + Data("\n".utf8))
        try? h.close()
    }

    private static func decode(_ data: Data) -> [LogEntry] {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? d.decode(LogEntry.self, from: Data($0)) }
    }
}
