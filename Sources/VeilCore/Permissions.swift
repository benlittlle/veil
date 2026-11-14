import Foundation
import CryptoKit
import Security

/// How far back the assistant can read in one chat. All is the default and behaves as before.
public enum HistoryWindow: String, Codable, Sendable, CaseIterable {
    case all
    case day = "24h"
    case week = "7d"
    case month = "30d"
    /// Only messages from the moment the user shared the chat (`ChatAccess.sharedSince`).
    case sinceShared = "since_shared"

    public var title: String {
        switch self {
        case .all: return "All"
        case .day: return "Last 24 hours"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .sinceShared: return "Only after I shared this chat"
        }
    }

    /// Told to the assistant. Says how far back the chat goes, never what's older.
    public var assistantNote: String? {
        switch self {
        case .all: return nil
        case .day: return "This chat shares the last 24 hours only."
        case .week: return "This chat shares the last 7 days only."
        case .month: return "This chat shares the last 30 days only."
        case .sinceShared: return "This chat shares only messages since the user shared it."
        }
    }

    var span: TimeInterval? {
        switch self {
        case .all, .sinceShared: return nil
        case .day: return 86_400
        case .week: return 7 * 86_400
        case .month: return 30 * 86_400
        }
    }
}

/// How long a chat stays shared. The chosen end time is stored in `ChatAccess.expires`.
public enum ShareDuration: String, Sendable, CaseIterable {
    case always
    case hour = "1h"
    case tonight
    case day = "24h"
    case week = "7d"

    public var title: String {
        switch self {
        case .always: return "Always"
        case .hour: return "1 hour"
        case .tonight: return "Until tonight"
        case .day: return "24 hours"
        case .week: return "7 days"
        }
    }

    /// When sharing ends if it starts at `now`. nil for Always. Tonight means the coming midnight.
    public func expiry(from now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .always: return nil
        case .hour: return now.addingTimeInterval(3600).wholeSeconds
        case .day: return now.addingTimeInterval(86_400).wholeSeconds
        case .week: return now.addingTimeInterval(7 * 86_400).wholeSeconds
        case .tonight:
            let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86_400)
            return midnight.wholeSeconds
        }
    }

    /// "45 more minutes", "3 more hours", "2 more days" (or "less than a minute").
    public static func remaining(until end: Date, now: Date) -> String {
        let s = end.timeIntervalSince(now)
        func n(_ v: Int, _ unit: String) -> String { "\(v) more \(unit)\(v == 1 ? "" : "s")" }
        if s < 60 { return "less than a minute" }
        if s < 3600 { return n(Int((s / 60).rounded(.up)), "minute") }
        if s < 86_400 * 2 { return n(max(1, Int((s / 3600).rounded())), "hour") }
        return n(Int((s / 86_400).rounded()), "day")
    }

    /// "45 min left", "3 hr left", "2 days left".
    public static func remainingShort(until end: Date, now: Date) -> String {
        let s = end.timeIntervalSince(now)
        if s < 60 { return "ending" }
        if s < 3600 { return "\(Int((s / 60).rounded(.up))) min left" }
        if s < 86_400 * 2 { return "\(max(1, Int((s / 3600).rounded()))) hr left" }
        return "\(Int((s / 86_400).rounded())) days left"
    }
}

extension Date {
    /// Stored times are whole seconds, so the signed encoding is the same after a round trip.
    public var wholeSeconds: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}

/// What the assistant may do with one conversation. Everything defaults to off.
public struct ChatAccess: Codable, Equatable, Sendable {
    public var read = false          // read & summarize message text
    public var waiting = false       // flag who's waiting on a reply
    public var draft = false         // save draft replies (never sends)
    public var send = false          // ask to send; the user approves each message
    public var attachments = false   // see photos & attachments
    public var hidden = false        // don't even reveal that the chat exists
    /// Text the assistant asks to send goes out without a prompt, within the rate limit.
    /// Only counts when `send` is on too (see `PermissionState.access`).
    public var autoSend = false
    /// See when messages come and go (time, direction, sender in groups), never what they say.
    public var activity = false
    /// Content filter: sensitive content is masked or withheld on this Mac before anything is returned.
    /// Off (false) is the default and behaves exactly as before.
    public var filtered = false
    /// This chat's own filter settings. nil means the default profile (`PermissionState.filterProfile`).
    public var filterPolicy: FilterPolicy?
    /// Messages the user chose to let through unfiltered (the user-only review screen). Kept sorted.
    public var filterAllowedMessages: [Int64] = []
    /// Photos (attachment ids) the user chose to share without the photo check. Kept sorted.
    public var filterAllowedPhotos: [Int64] = []
    /// How far back the assistant can read. All (the default) behaves exactly as before.
    public var history: HistoryWindow = .all
    /// When access last went from nothing to something. Bookkeeping kept by `settled(after:now:)`,
    /// cleared while nothing is shared. "Only after I shared this chat" reads from here.
    public var sharedSince: Date? { didSet { sharedSince = sharedSince?.wholeSeconds } }
    /// When sharing ends on its own. nil means Always. At this time every switch goes off.
    public var expires: Date? { didSet { expires = expires?.wholeSeconds } }

    public init(read: Bool = false, waiting: Bool = false, draft: Bool = false,
                send: Bool = false, attachments: Bool = false, hidden: Bool = false, autoSend: Bool = false,
                activity: Bool = false, filtered: Bool = false, filterPolicy: FilterPolicy? = nil,
                filterAllowedMessages: [Int64] = [], filterAllowedPhotos: [Int64] = [],
                history: HistoryWindow = .all, sharedSince: Date? = nil, expires: Date? = nil) {
        self.read = read; self.waiting = waiting; self.draft = draft
        self.send = send; self.attachments = attachments; self.hidden = hidden; self.autoSend = autoSend
        self.activity = activity
        self.filtered = filtered; self.filterPolicy = filterPolicy
        self.filterAllowedMessages = Array(Set(filterAllowedMessages)).sorted()
        self.filterAllowedPhotos = Array(Set(filterAllowedPhotos)).sorted()
        self.history = history
        self.sharedSince = sharedSince?.wholeSeconds
        self.expires = expires?.wholeSeconds
    }

    /// The same chat with every switch off, keeping its content-filter settings and history choice, so
    /// turning things off and on again never silently drops them. The time limit ends with the sharing.
    public var allOffKeepingFilter: ChatAccess {
        ChatAccess(hidden: hidden, filtered: filtered, filterPolicy: filterPolicy, filterAllowedMessages: filterAllowedMessages,
                   filterAllowedPhotos: filterAllowedPhotos, history: history)
    }

    /// Any switch that shares something is on (ignores Hide, which keeps the switches underneath).
    public var hasAnySwitch: Bool { read || waiting || draft || send || attachments || activity }

    /// The time limit has run out.
    public func expired(at now: Date) -> Bool { expires.map { $0 <= now } ?? false }

    /// The oldest moment the assistant may see in this chat, or nil for all of it. "Only after I shared
    /// this chat" with no recorded time shows nothing older than now (fail closed).
    public func historyCutoff(now: Date) -> Date? {
        switch history {
        case .all: return nil
        case .sinceShared: return sharedSince ?? now
        default: return now.addingTimeInterval(-(history.span ?? 0))
        }
    }

    /// This chat after a change from `before`, with the sharing bookkeeping kept consistent. Every change
    /// to a chat's switches goes through here (the app and the assistant's settings tools alike):
    /// - a time limit that has run out locks the chat;
    /// - `sharedSince` is recorded when access goes from nothing to something, and kept while any stays on;
    /// - with nothing shared, there's no time limit and no `sharedSince`.
    public func settled(after before: ChatAccess, now: Date) -> ChatAccess {
        var a = self
        if a.expired(at: now) { a = a.allOffKeepingFilter }
        if !a.hasAnySwitch {
            a.sharedSince = nil; a.expires = nil
        } else if !before.hasAnySwitch || before.expired(at: now) {
            a.sharedSince = now
        } else {
            // Files from before this existed have no time: "since shared" then starts now.
            a.sharedSince = before.sharedSince ?? (a.history == .sinceShared ? now : nil)
        }
        return a
    }

    /// Timing metadata is visible: either the Activity switch, or Read (which shows everything anyway).
    public var seesActivity: Bool { !hidden && (read || activity) }

    // Newer settings are written only when switched on, so a permissions file signed by an
    // older version re-encodes to the same bytes and still verifies.
    private enum CodingKeys: String, CodingKey {
        case read, waiting, draft, send, attachments, hidden, autoSend, activity, filtered, filterPolicy, filterAllowedMessages, filterAllowedPhotos
        case history, sharedSince, expires
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        read = try c.decode(Bool.self, forKey: .read); waiting = try c.decode(Bool.self, forKey: .waiting)
        draft = try c.decode(Bool.self, forKey: .draft); send = try c.decode(Bool.self, forKey: .send)
        attachments = try c.decode(Bool.self, forKey: .attachments); hidden = try c.decode(Bool.self, forKey: .hidden)
        autoSend = try c.decodeIfPresent(Bool.self, forKey: .autoSend) ?? false
        activity = try c.decodeIfPresent(Bool.self, forKey: .activity) ?? false
        filtered = try c.decodeIfPresent(Bool.self, forKey: .filtered) ?? false
        filterPolicy = try c.decodeIfPresent(FilterPolicy.self, forKey: .filterPolicy)
        filterAllowedMessages = try c.decodeIfPresent([Int64].self, forKey: .filterAllowedMessages) ?? []
        filterAllowedPhotos = try c.decodeIfPresent([Int64].self, forKey: .filterAllowedPhotos) ?? []
        // An unknown value fails to decode, so the file is treated as unreadable and everything stays off.
        history = try c.decodeIfPresent(HistoryWindow.self, forKey: .history) ?? .all
        sharedSince = try c.decodeIfPresent(Int64.self, forKey: .sharedSince).map { Date(timeIntervalSince1970: TimeInterval($0)) }
        expires = try c.decodeIfPresent(Int64.self, forKey: .expires).map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(read, forKey: .read); try c.encode(waiting, forKey: .waiting); try c.encode(draft, forKey: .draft)
        try c.encode(send, forKey: .send); try c.encode(attachments, forKey: .attachments); try c.encode(hidden, forKey: .hidden)
        if autoSend { try c.encode(true, forKey: .autoSend) }
        if activity { try c.encode(true, forKey: .activity) }
        if filtered { try c.encode(true, forKey: .filtered) }
        try c.encodeIfPresent(filterPolicy, forKey: .filterPolicy)
        if !filterAllowedMessages.isEmpty { try c.encode(filterAllowedMessages, forKey: .filterAllowedMessages) }
        if !filterAllowedPhotos.isEmpty { try c.encode(filterAllowedPhotos, forKey: .filterAllowedPhotos) }
        // All, no recorded time and Always are left out, so files signed before these existed still verify.
        if history != .all { try c.encode(history, forKey: .history) }
        if let d = sharedSince { try c.encode(Int64(d.timeIntervalSince1970), forKey: .sharedSince) }
        if let d = expires { try c.encode(Int64(d.timeIntervalSince1970), forKey: .expires) }
    }

    public static let none = ChatAccess()

    /// Flips one switch the way the app's toggles do: turning Send off also turns auto-send off,
    /// so turning Send back on never revives it. The app and the assistant's settings tools both use this.
    public mutating func set(_ key: WritableKeyPath<ChatAccess, Bool>, _ on: Bool) {
        self[keyPath: key] = on
        if key == \.send && !on { autoSend = false }
        if key == \.autoSend { autoSend = on && send }
    }

    public var anyEnabled: Bool { !hidden && (read || waiting || draft || send || attachments || activity) }
}

/// How many messages may be auto-sent to one chat in a window. Over that, the user is asked.
public struct AutoSendLimit: Codable, Equatable, Sendable {
    public var count: Int
    public var minutes: Int
    public init(count: Int, minutes: Int) { self.count = count; self.minutes = minutes }
    public static let standard = AutoSendLimit(count: 5, minutes: 10)
    public static let counts = 1...50
    public static let minuteRange = 1...(24 * 60)
    /// Kept inside the ranges the app offers.
    public var clamped: AutoSendLimit {
        AutoSendLimit(count: min(max(count, Self.counts.lowerBound), Self.counts.upperBound),
                      minutes: min(max(minutes, Self.minuteRange.lowerBound), Self.minuteRange.upperBound))
    }
}

/// Whether the assistant may change Veil's settings over MCP. Changed only in the app, never by a tool.
public enum AgentSettingsMode: String, Codable, Sendable, CaseIterable {
    /// No settings tools exist for the assistant (the default).
    case off
    /// The assistant can ask; the user approves each change in a prompt.
    case ask
    /// Changes apply right away, with a notification. Allowing PINs & codes still asks.
    case direct

    public var title: String {
        switch self { case .off: return "Off"; case .ask: return "Ask me"; case .direct: return "Apply directly" }
    }
}

public struct PermissionState: Codable, Equatable, Sendable {
    public var generation: UInt64 = 0
    public var paused = false
    public var chats: [String: ChatAccess] = [:]
    /// Conversations the user has looked at. Anything not in here shows up under "New chats".
    /// Kept sorted so the signed encoding is deterministic.
    public private(set) var reviewed: [String] = []
    /// Kill switch: no chat auto-sends while this is on. Per-chat choices are kept.
    public var autoSendStopped = false
    /// nil means `AutoSendLimit.standard`.
    public var autoSendLimit: AutoSendLimit?
    /// The default content-filter profile for filtered chats. nil means `FilterPolicy.standard`.
    public var filterProfile: FilterPolicy?
    /// Whether the assistant may change settings over MCP. Only the app changes this.
    public var agentSettings: AgentSettingsMode = .off
    public init() {}

    public var effectiveAutoSendLimit: AutoSendLimit { autoSendLimit ?? .standard }
    public var effectiveFilterProfile: FilterPolicy { filterProfile ?? .standard }

    /// The filter that applies to a chat's content, or nil when the chat's filter is Off.
    public func filterPolicy(for chatID: String) -> FilterPolicy? {
        guard let a = chats[chatID], a.filtered else { return nil }
        return a.filterPolicy ?? effectiveFilterProfile
    }

    private enum CodingKeys: String, CodingKey { case generation, paused, chats, reviewed, autoSendStopped, autoSendLimit, filterProfile, agentSettings }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        generation = try c.decode(UInt64.self, forKey: .generation)
        paused = try c.decode(Bool.self, forKey: .paused)
        chats = try c.decode([String: ChatAccess].self, forKey: .chats)
        reviewed = try c.decode([String].self, forKey: .reviewed)
        autoSendStopped = try c.decodeIfPresent(Bool.self, forKey: .autoSendStopped) ?? false
        autoSendLimit = try c.decodeIfPresent(AutoSendLimit.self, forKey: .autoSendLimit)
        filterProfile = try c.decodeIfPresent(FilterPolicy.self, forKey: .filterProfile)
        // An unknown value fails to decode, so the file is treated as unreadable and everything stays off.
        agentSettings = try c.decodeIfPresent(AgentSettingsMode.self, forKey: .agentSettings) ?? .off
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(generation, forKey: .generation); try c.encode(paused, forKey: .paused)
        try c.encode(chats, forKey: .chats); try c.encode(reviewed, forKey: .reviewed)
        if autoSendStopped { try c.encode(true, forKey: .autoSendStopped) }
        try c.encodeIfPresent(autoSendLimit, forKey: .autoSendLimit)
        try c.encodeIfPresent(filterProfile, forKey: .filterProfile)
        // Off is left out, so files signed before this setting existed re-encode to the same bytes.
        if agentSettings != .off { try c.encode(agentSettings, forKey: .agentSettings) }
    }

    /// Stores a rate limit, kept inside the ranges the app offers. The standard one is left out of the file.
    public mutating func setAutoSendLimit(_ limit: AutoSendLimit) {
        let l = limit.clamped
        autoSendLimit = l == .standard ? nil : l
    }

    public mutating func markReviewed<S: Sequence>(_ ids: S) where S.Element == String {
        reviewed = Array(Set(reviewed).union(ids)).sorted()
    }

    /// The single source of truth for policy decisions. Hidden or paused means nothing, and so does a
    /// share whose time limit has run out, even before the lock has been written to the file.
    public func access(_ chatID: String, now: Date = Date()) -> ChatAccess {
        var a = chats[chatID] ?? .none
        if a.hidden { return ChatAccess(hidden: true) }
        if paused { return .none }
        if a.expired(at: now) { return a.allOffKeepingFilter }
        if !a.send || autoSendStopped { a.autoSend = false }
        return a
    }

    /// The oldest moment the assistant may see in a chat, or nil for all of it.
    public func historyCutoff(_ chatID: String, now: Date) -> Date? {
        chats[chatID]?.historyCutoff(now: now)
    }

    /// Chats whose time limit has run out.
    public func expiredChats(now: Date) -> [String] {
        chats.filter { $0.value.expired(at: now) }.map(\.key).sorted()
    }

    /// Locks every chat whose time limit has run out (every switch off, auto-send included). Returns their ids.
    @discardableResult
    public mutating func lockExpired(now: Date) -> [String] {
        let ids = expiredChats(now: now)
        for id in ids { if let a = chats[id] { chats[id] = a.settled(after: a, now: now) } }
        return ids
    }
}

/// Where the signing key lives. The real one is the macOS Keychain.
public protocol SecretStore: AnyObject {
    /// Returns (key, generation) or nil if nothing stored yet.
    func load() throws -> (Data, UInt64)?
    func save(key: Data, generation: UInt64) throws
}

/// Persists permissions as JSON plus an HMAC. The HMAC key and the latest generation
/// counter live in the Keychain, so another process can neither forge a file nor roll
/// back to an older one without the user noticing. On any mismatch we fail closed.
public final class PermissionStore {
    public enum Integrity: Equatable { case ok, firstRun, tampered(String) }

    private struct File: Codable { var state: PermissionState; var mac: String }
    struct KeyUnavailable: LocalizedError {
        var errorDescription: String? { "Veil can't reach its key in your Keychain. Unlock your Mac's Keychain, then try again." }
    }

    private let url: URL
    private let secrets: SecretStore
    private let lock = NSLock()
    private var current = PermissionState()
    private var key: Data?                      // nil until the Keychain gives us a valid 32-byte key
    private var _integrity: Integrity = .firstRun
    private var keyMissing = false              // a permissions file exists but the Keychain has no key for it

    public init(url: URL, secrets: SecretStore) {
        self.url = url
        self.secrets = secrets
        lock.lock(); load(); lock.unlock()
    }

    public var state: PermissionState { lock.lock(); defer { lock.unlock() }; return current }
    public var integrity: Integrity { lock.lock(); defer { lock.unlock() }; return _integrity }
    /// True when the permissions file exists but no signing key does. Everything is off until the user
    /// brings the key back (e.g. from an older install) or starts fresh.
    public var signingKeyMissing: Bool { lock.lock(); defer { lock.unlock() }; return keyMissing }

    /// Re-reads the key and the file, e.g. after the user imported a key. Fails closed like a launch.
    public func reload() { lock.lock(); load(); lock.unlock() }

    /// Must be called with the lock held. On any problem `current` stays all-off.
    private func load() {
        current = PermissionState()
        keyMissing = false
        do {
            guard let (k, gen) = try secrets.load() else {
                // A permissions file with no key to check it against (a reset Keychain, or a key that
                // couldn't be brought over from an older install): fail closed and say so.
                if FileManager.default.fileExists(atPath: url.path) {
                    key = nil
                    keyMissing = true
                    _integrity = .tampered("The key that signs your permissions isn't in your Keychain, so the permissions file can't be checked.")
                    return
                }
                let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                try secrets.save(key: fresh, generation: 0)
                key = fresh
                _integrity = .firstRun
                return
            }
            guard k.count == 32 else { key = nil; _integrity = .tampered("The Keychain key is invalid."); return }
            key = k
            guard let data = try? Data(contentsOf: url) else {
                _integrity = gen == 0 ? .firstRun : .tampered("The permissions file is missing.")
                return
            }
            let file = try JSONDecoder().decode(File.self, from: data)
            guard file.mac == mac(file.state, k) else { _integrity = .tampered("The permissions file was edited outside Veil."); return }
            // gen + 1 means the file was saved but the Keychain update didn't land; a forged file
            // still can't pass the MAC, so accepting it doesn't allow rollback.
            if file.state.generation == gen + 1 { try? secrets.save(key: k, generation: gen + 1) }
            else if file.state.generation != gen { _integrity = .tampered("The permissions file was replaced with an older copy."); return }
            current = file.state
            _integrity = .ok
        } catch {
            key = nil
            _integrity = .tampered("Couldn't read the Keychain to verify permissions (\(error.localizedDescription)).")
        }
    }

    /// Changes the signed state atomically. Called by the app, and by the gate's settings tools only
    /// when the user set "Assistant can change settings" to Ask me or Apply directly. If `change`
    /// throws, nothing is saved.
    public func update(_ change: (inout PermissionState) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard let key else { throw KeyUnavailable() }
        var next = current
        try change(&next)
        next.generation = current.generation + 1
        let data = try JSONEncoder.sorted.encode(File(state: next, mac: mac(next, key)))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try secrets.save(key: key, generation: next.generation)
        current = next
        _integrity = .ok
    }

    /// Start over with everything off. Re-reads the Keychain first in case it was locked at launch.
    public func reset() throws {
        lock.lock()
        if key == nil { load() }
        if key == nil && keyMissing {
            // Starting fresh is how the user gets past a missing key: make a new one. The old file is
            // overwritten with everything off by the update below.
            let fresh = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
            do { try secrets.save(key: fresh, generation: 0) } catch { lock.unlock(); throw error }
            key = fresh
            keyMissing = false
        }
        let ready = key != nil
        lock.unlock()
        guard ready else { throw KeyUnavailable() }
        try update { $0 = PermissionState() }
    }

    private func mac(_ s: PermissionState, _ key: Data) -> String {
        let body = (try? JSONEncoder.sorted.encode(s)) ?? Data()
        return Data(HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: key))).base64EncodedString()
    }
}

extension JSONEncoder {
    static var sorted: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]; return e }
}

/// Keychain-backed secret: 32-byte key followed by an 8-byte generation counter.
public final class KeychainSecretStore: SecretStore {
    private let service: String
    private let allowUI: Bool
    /// `allowUI: false` never shows a Keychain prompt: a read that would need the user's approval fails instead.
    public init(service: String = "Veil permissions key", allowUI: Bool = true) { self.service = service; self.allowUI = allowUI }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "hmac"]
    }

    /// Whether the item exists. Reads attributes only, so it never needs the user's approval.
    public func exists() -> Bool { KeychainPrompts.itemExists(query) }

    public func load() throws -> (Data, UInt64)? {
        var q = query; q[kSecReturnData as String] = true
        var out: CFTypeRef?
        let status = KeychainPrompts.copyMatching(q, allowUI: allowUI, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let d = out as? Data, d.count == 40 else { throw KeychainError(status: status) }
        let gen = d.suffix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        return (d.prefix(32), UInt64(littleEndian: gen))
    }

    public func save(key: Data, generation: UInt64) throws {
        guard key.count == 32 else { throw KeychainError(status: errSecParam) }
        var g = generation.littleEndian
        let blob = key + Data(bytes: &g, count: 8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: blob] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = blob
            add[kSecAttrLabel as String] = "Veil permissions key"
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw KeychainError(status: s) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "")" }
    }
}

/// Runs Keychain reads with prompts turned off when asked to.
enum KeychainPrompts {
    static func copyMatching(_ query: [String: Any], allowUI: Bool, _ out: inout CFTypeRef?) -> OSStatus {
        if allowUI { return SecItemCopyMatching(query as CFDictionary, &out) }
        var q = query
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        // Legacy (file-based) Keychain items ask through SecurityAgent; this makes those reads fail
        // (errSecAuthFailed / errSecInteractionNotAllowed) instead of showing a dialog.
        var was: DarwinBoolean = true
        SecKeychainGetUserInteractionAllowed(&was)
        SecKeychainSetUserInteractionAllowed(false)
        defer { SecKeychainSetUserInteractionAllowed(was.boolValue) }
        return SecItemCopyMatching(q as CFDictionary, &out)
    }

    static func itemExists(_ query: [String: Any]) -> Bool {
        var q = query; q[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        let s = copyMatching(q, allowUI: false, &out)
        return s == errSecSuccess || s == errSecInteractionNotAllowed || s == errSecAuthFailed
    }
}

/// In-memory secret store for tests and demo mode.
public final class MemorySecretStore: SecretStore {
    public var stored: (Data, UInt64)?
    public init() {}
    public func load() throws -> (Data, UInt64)? { stored }
    public func save(key: Data, generation: UInt64) throws { stored = (key, generation) }
}
