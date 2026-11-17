import Foundation

/// Whether a connected assistant could skip the gate and read chat.db itself.
///
/// macOS attributes file access to the *responsible* process, so the `veil-mcp` relay runs under
/// the Full Disk Access of the app that launched it (Claude Desktop, Cursor, a terminal, …). On
/// startup the relay calls `open()` on chat.db and closes it straight away, without reading a byte,
/// and tells Veil the result in a one-line hello before relaying anything. See `RelayHello`.
public enum ChatDBReach: String, Codable, Sendable, Equatable {
    /// The relay could open chat.db, so the assistant's host app can read Messages without Veil.
    case readable
    /// The relay could not open chat.db. Veil is the only way in for this assistant.
    case blocked
    /// Connected over the local web address: there's no relay running under the assistant to ask.
    case cantCheckHTTP
    /// A relay from before this check, or some other process on the socket that didn't say.
    case cantCheckOldRelay
}

/// The relay's first line on the socket. A JSON-RPC notification (no `id`), so a Veil that doesn't
/// know it ignores it without replying, and the assistant never sees it either way.
public enum RelayHello {
    public static let method = "veil/relayHello"
    /// Version of the hello itself, for later additions.
    public static let version = 1

    public static func line(chatDBReadable: Bool) -> String {
        JSON.object(["jsonrpc": "2.0", "method": .string(method),
                     "params": ["relayVersion": JSON(version), "chatDbReadable": .bool(chatDBReadable)]]).encoded() + "\n"
    }
}

/// One assistant as Veil last saw it, keyed by the name it gives itself.
public struct ClientCheck: Codable, Equatable, Sendable, Identifiable {
    public enum Transport: String, Codable, Sendable { case relay, http }
    public var name: String
    public var transport: Transport
    public var reach: ChatDBReach
    public var lastSeen: Date
    public var id: String { name }

    public init(name: String, transport: Transport, reach: ChatDBReach, lastSeen: Date = Date()) {
        self.name = name; self.transport = transport; self.reach = reach; self.lastSeen = lastSeen
    }

    public var canBypass: Bool { reach == .readable }

    /// One neutral line for the menu bar, Connect and Setup & safety. Many agent setups run with
    /// Full Disk Access on purpose, so this states the fact; it isn't an alarm.
    public var headline: String {
        switch reach {
        case .readable: return "\(name) runs with Full Disk Access"
        case .blocked: return "\(name) goes through Veil for Messages"
        case .cantCheckHTTP, .cantCheckOldRelay: return "Can't check \(name)"
        }
    }

    public var detail: String {
        switch reach {
        case .readable:
            return "So it could read Messages directly. Veil's limits only apply to what it asks Veil for."
        case .blocked:
            return "Checked when it connected: the app it runs in can't open the Messages database itself."
        case .cantCheckHTTP:
            return "It connects over the local web address, so Veil can't tell whether the app it runs in has Full Disk Access."
        case .cantCheckOldRelay:
            return "It connected through an older relay that doesn't report this. Restart it after updating Veil to check."
        }
    }

    /// Status line once the user has said they know.
    public static let acknowledgedLine = "Has Full Disk Access (acknowledged)"
}

/// "I understand, don't warn me again", per assistant name. Not security-critical (it only quiets a
/// notice), so it lives in UserDefaults. A check that comes back *without* Full Disk Access clears
/// it, so if the assistant later has it again, the notice returns.
public final class BypassAcknowledgements: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "acknowledgedFullDiskAccess") {
        self.defaults = defaults; self.key = key
    }

    private var names: Set<String> { Set(defaults.stringArray(forKey: key) ?? []) }
    private func save(_ n: Set<String>) { defaults.set(n.sorted(), forKey: key) }

    public func isAcknowledged(_ name: String) -> Bool { names.contains(name) }
    public func acknowledge(_ name: String) { save(names.union([name])) }
    public func unacknowledge(_ name: String) { save(names.subtracting([name])) }

    /// Called for every new check. "Can't check" results leave the acknowledgement alone.
    public func update(for check: ClientCheck) {
        if check.reach == .blocked, isAcknowledged(check.name) { unacknowledge(check.name) }
    }

    /// Readable and not acknowledged: show the notice.
    public func needsNotice(_ c: ClientCheck) -> Bool { c.canBypass && !isAcknowledged(c.name) }
}

/// Remembers the last check per assistant name, so a warning stays visible after it disconnects.
/// Stored as a small JSON file (no message data). `url == nil` keeps it in memory.
public final class ClientCheckStore: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var checks: [String: ClientCheck] = [:]
    public var onChange: (() -> Void)?

    public init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder.iso.decode([ClientCheck].self, from: data) {
            for c in list { checks[c.name] = c }
        }
    }

    public var all: [ClientCheck] {
        lock.lock(); defer { lock.unlock() }
        // Warnings first, then by name.
        return checks.values.sorted { ($0.canBypass ? 0 : 1, $0.name.lowercased()) < ($1.canBypass ? 0 : 1, $1.name.lowercased()) }
    }

    public var bypassing: [ClientCheck] { all.filter(\.canBypass) }

    /// At most this many are remembered. Names come from the clients, so without a cap a client could grow
    /// the list (and the file) without end. The oldest go first, warnings last.
    public static let limit = 30

    public func record(_ c: ClientCheck) {
        lock.lock()
        checks[c.name] = c
        if checks.count > Self.limit {
            let drop = checks.values.sorted { ($0.canBypass ? 1 : 0, $0.lastSeen) < ($1.canBypass ? 1 : 0, $1.lastSeen) }
                .filter { $0.name != c.name }.prefix(checks.count - Self.limit)
            for d in drop { checks[d.name] = nil }
        }
        let list = Array(checks.values)
        lock.unlock()
        save(list); onChange?()
    }

    public func forget(_ name: String) {
        lock.lock(); checks[name] = nil; let list = Array(checks.values); lock.unlock()
        save(list); onChange?()
    }

    private func save(_ list: [ClientCheck]) {
        guard let url else { return }
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys, .prettyPrinted]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? e.encode(list.sorted { $0.name < $1.name }).write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}
