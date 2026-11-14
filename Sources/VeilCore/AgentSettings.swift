import Foundation

// Settings the assistant may change over MCP, only while the user has set "Assistant can change
// settings" to Ask me or Apply directly (`PermissionState.agentSettings`). That mode itself, hidden
// chats, the webhook, the local web address, keys and the app's look are never reachable from here.

/// App preferences kept outside the signed permissions (UserDefaults in the app). Must be thread-safe:
/// the gate reads and writes them from MCP connection threads.
public protocol AppPreferences: AnyObject {
    var assistantName: String { get }
    var newMessagePings: Bool { get }
    var pingWhenIReply: Bool { get }
    /// Applies whichever values are non-nil.
    func update(assistantName: String?, newMessagePings: Bool?, pingWhenIReply: Bool?)
}

/// In-memory preferences for tests and as a default.
public final class MemoryPreferences: AppPreferences {
    private let lock = NSLock()
    private var name: String, pings: Bool, replies: Bool
    public init(assistantName: String = "Assistant", newMessagePings: Bool = false, pingWhenIReply: Bool = true) {
        name = assistantName; pings = newMessagePings; replies = pingWhenIReply
    }
    public var assistantName: String { lock.lock(); defer { lock.unlock() }; return name }
    public var newMessagePings: Bool { lock.lock(); defer { lock.unlock() }; return pings }
    public var pingWhenIReply: Bool { lock.lock(); defer { lock.unlock() }; return replies }
    public func update(assistantName: String?, newMessagePings: Bool?, pingWhenIReply: Bool?) {
        lock.lock(); defer { lock.unlock() }
        if let assistantName { name = assistantName }
        if let newMessagePings { pings = newMessagePings }
        if let pingWhenIReply { replies = pingWhenIReply }
    }
}

/// One plain-language line about a change, e.g. "turn on Read" / "Read on".
public struct SettingLine: Equatable, Sendable {
    /// For the approval prompt: "turn on Auto-send".
    public let phrase: String
    /// For the activity log and notifications: "Auto-send on (5 per 10 min)".
    public let short: String
    /// Goes after the chat name in the prompt: "turn on Auto-send for Mom (5 per 10 min)".
    public var detail = ""
}

/// A partial update to one chat. Only the fields that are set change.
public struct ChatSettingsChange: Equatable, Sendable {
    public enum Switch: String, CaseIterable, Sendable {
        case read, activity, waiting, drafts, send, photos
        var keyPath: WritableKeyPath<ChatAccess, Bool> {
            switch self {
            case .read: return \.read
            case .activity: return \.activity
            case .waiting: return \.waiting
            case .drafts: return \.draft
            case .send: return \.send
            case .photos: return \.attachments
            }
        }
        public var title: String {
            switch self {
            case .read: return "Read"
            case .activity: return "See activity"
            case .waiting: return "Notice who's waiting"
            case .drafts: return "Write drafts"
            case .send: return "Send with your OK"
            case .photos: return "See photos & files"
            }
        }
    }

    public var switches: [Switch: Bool] = [:]
    public var autoSend: Bool?
    public var filterOn: Bool?
    public var actions: [FilterCategory: FilterAction] = [:]
    public var strictness: FilterStrictness?
    public var photoMode: PhotoMode?
    public init() {}

    var changesPolicy: Bool { !actions.isEmpty || strictness != nil || photoMode != nil }

    /// The chat's settings after this change. Throws (and nothing is saved) when the result breaks a rule.
    public func applied(to before: ChatAccess, in state: PermissionState) throws -> ChatAccess {
        var a = before
        for s in Switch.allCases { if let v = switches[s] { a.set(s.keyPath, v) } }
        if let on = autoSend {
            if on && !a.send {
                throw SettingsError("Auto-send needs Send turned on for this chat. Include \"send\": true, or leave auto_send out.")
            }
            a.set(\.autoSend, on)
        }
        if let on = filterOn { a.filtered = on }
        if changesPolicy {
            var p = a.filterPolicy ?? state.effectiveFilterProfile
            for (c, act) in actions { p.set(c, act) }
            if let s = strictness { p.strictness = s }
            if let m = photoMode { p.attachments = m }
            a.filterPolicy = p
        }
        return a
    }

    /// PINs & verification codes reach the assistant: the filter is off, or it allows them.
    static func codesVisible(_ a: ChatAccess, _ state: PermissionState) -> Bool {
        !a.filtered || (a.filterPolicy ?? state.effectiveFilterProfile).action(.codes) == .allow
    }

    /// True when this change would let codes through where they were masked or withheld. The app
    /// asks the user to confirm that, so the assistant always needs the user's approval for it.
    public func allowsCodes(from before: ChatAccess, in state: PermissionState) -> Bool {
        guard let after = try? applied(to: before, in: state) else { return false }
        return !Self.codesVisible(before, state) && Self.codesVisible(after, state)
    }

    /// What actually changes, in plain language. Empty when every value is already set.
    public func lines(from before: ChatAccess, in state: PermissionState) -> [SettingLine] {
        guard let after = try? applied(to: before, in: state) else { return [] }
        var out: [SettingLine] = []
        func toggle(_ title: String, _ was: Bool, _ now: Bool, _ extra: String = "") {
            guard was != now else { return }
            out.append(SettingLine(phrase: "turn \(now ? "on" : "off") \(title)", short: "\(title) \(now ? "on" : "off")\(extra)", detail: extra))
        }
        for s in Switch.allCases { toggle(s.title, before[keyPath: s.keyPath], after[keyPath: s.keyPath]) }
        let l = state.effectiveAutoSendLimit
        toggle("Auto-send", before.autoSend && before.send, after.autoSend && after.send, after.autoSend ? " (\(l.count) per \(l.minutes) min)" : "")
        toggle("the content filter", before.filtered, after.filtered)
        let p0 = before.filterPolicy ?? state.effectiveFilterProfile, p1 = after.filterPolicy ?? state.effectiveFilterProfile
        for c in FilterCategory.allCases where p0.action(c) != p1.action(c) {
            out.append(SettingLine(phrase: "set filter “\(c.title)” to \(p1.action(c).title)", short: "\(c.title): \(p1.action(c).title)"))
        }
        if p0.strictness != p1.strictness {
            out.append(SettingLine(phrase: "set filter strictness to \(p1.strictness.title)", short: "Strictness: \(p1.strictness.title)"))
        }
        if p0.attachments != p1.attachments {
            out.append(SettingLine(phrase: "set filtered photos & files to \(p1.attachments.title)", short: "Photos & files: \(p1.attachments.title)"))
        }
        return out
    }
}

/// A partial update to app-level settings. Only the fields that are set change.
public struct AppSettingsChange: Equatable, Sendable {
    public var paused: Bool?
    public var assistantName: String?
    public var newMessagePings: Bool?
    public var pingWhenIReply: Bool?
    /// The switch for every chat's auto-send (the inverse of `PermissionState.autoSendStopped`).
    public var autoSendAllowed: Bool?
    public var autoSendLimit: AutoSendLimit?
    public init() {}

    public func lines(state: PermissionState, prefs: AppPreferences) -> [SettingLine] {
        var out: [SettingLine] = []
        if let p = paused, p != state.paused {
            out.append(p ? SettingLine(phrase: "pause Veil (every tool stops until you unpause it)", short: "Paused")
                         : SettingLine(phrase: "unpause Veil", short: "Unpaused"))
        }
        if let n = assistantName, n != prefs.assistantName {
            out.append(SettingLine(phrase: "rename the assistant to “\(n)”", short: "Assistant name: “\(n)”"))
        }
        if let v = newMessagePings, v != prefs.newMessagePings {
            out.append(SettingLine(phrase: "turn \(v ? "on" : "off") new-message pings", short: "New-message pings \(v ? "on" : "off")"))
        }
        if let v = pingWhenIReply, v != prefs.pingWhenIReply {
            out.append(SettingLine(phrase: "turn \(v ? "on" : "off") Ping when I reply", short: "Ping when I reply \(v ? "on" : "off")"))
        }
        if let v = autoSendAllowed, v == state.autoSendStopped {
            out.append(v ? SettingLine(phrase: "allow auto-send again for chats set to it", short: "Auto-send allowed")
                         : SettingLine(phrase: "stop auto-send for every chat", short: "Auto-send stopped"))
        }
        if let l = autoSendLimit, l != state.effectiveAutoSendLimit {
            out.append(SettingLine(phrase: "set the auto-send limit to \(l.count) per \(l.minutes) min", short: "Auto-send limit: \(l.count) per \(l.minutes) min"))
        }
        return out
    }
}

/// A rule the change breaks. The message goes back to the assistant.
public struct SettingsError: Error, Equatable {
    public let message: String
    init(_ m: String) { message = m }
}

/// A change the assistant asked for, waiting for (or decided by) the user.
public struct SettingsRequest: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case pending, applying, approved, declined, expired, cancelled(String)
        public var label: String {
            switch self {
            case .pending, .applying: return "pending"
            case .approved: return "approved"
            case .declined: return "declined"
            case .expired: return "expired"
            case .cancelled: return "cancelled"
            }
        }
    }
    public enum Target: Equatable, Sendable {
        case chat(id: String, name: String, change: ChatSettingsChange)
        case app(AppSettingsChange)
    }
    public let id: String
    public let target: Target
    /// What the user is asked to allow, in plain language, as worked out when the request came in.
    public let lines: [SettingLine]
    public let created: Date
    /// The assistant's own name for itself. Untrusted: shown only as a cleaned-up label.
    public let client: String
    /// Why this needs approval even in Apply directly (allowing PINs & codes), if it does.
    public let caution: String?
    public var status: Status

    public var chatID: String? { if case .chat(let id, _, _) = target { return id }; return nil }
    public var chatName: String? { if case .chat(_, let n, _) = target { return n }; return nil }
    /// "turn on Read for Mom"
    public var phrases: [String] { lines.map { l in (chatName.map { "\(l.phrase) for \($0)" } ?? l.phrase) + l.detail } }
    /// "Read on, Auto-send on (5 per 10 min)"
    public var shortSummary: String { lines.map(\.short).joined(separator: ", ") }
}

// MARK: - Parsing the assistant's arguments (strict: unknown keys and wrong types are errors)

extension FilterCategory {
    /// The name used in the MCP tools.
    public var mcpName: String {
        switch self {
        case .cardNumbers: return "card_numbers"
        case .codes: return "codes"
        case .bankDetails: return "bank_details"
        case .governmentIDs: return "id_numbers"
        case .secrets: return "passwords_and_keys"
        case .profanity: return "swearing"
        case .politics: return "politics"
        case .health: return "health"
        case .sexual: return "sexual"
        case .conflict: return "arguments_and_insults"
        case .moneyWorries: return "money_worries"
        case .idDocuments: return "id_documents"
        case .paymentCards: return "payment_cards"
        case .personalDocuments: return "letters_and_documents"
        case .privateScreenshots: return "private_screenshots"
        case .nudity: return "nudity"
        }
    }
    init?(mcpName: String) {
        guard let c = FilterCategory.allCases.first(where: { $0.mcpName == mcpName }) else { return nil }
        self = c
    }
}

enum SettingsArgs {
    static let chatKeys = ["chat_id"] + ChatSettingsChange.Switch.allCases.map(\.rawValue) + ["auto_send", "filter"]
    static let filterKeys = ["on", "strictness", "photos", "categories"]
    static let appKeys = ["paused", "assistant_name", "new_message_pings", "ping_when_i_reply", "auto_send", "auto_send_limit"]
    static let limitKeys = ["count", "minutes"]

    static func object(_ j: JSON, _ what: String) throws -> [String: JSON] {
        guard case .object(let o) = j else { throw SettingsError("\(what) must be an object.") }
        return o
    }

    static func onlyKnown(_ o: [String: JSON], _ allowed: [String], _ where_: String) throws {
        let unknown = o.keys.filter { !allowed.contains($0) }.sorted()
        guard unknown.isEmpty else {
            throw SettingsError("Unknown setting\(unknown.count == 1 ? "" : "s")\(where_): \(unknown.joined(separator: ", ")). "
                                + "Allowed: \(allowed.joined(separator: ", ")). Nothing was changed.")
        }
    }

    static func bool(_ o: [String: JSON], _ k: String) throws -> Bool? {
        guard let v = o[k] else { return nil }
        guard let b = v.bool else { throw SettingsError("\(k) must be true or false.") }
        return b
    }

    static func choice<T: RawRepresentable>(_ o: [String: JSON], _ k: String, _ type: T.Type, _ options: [T]) throws -> T? where T.RawValue == String {
        guard let v = o[k] else { return nil }
        guard let s = v.string, let t = T(rawValue: s), options.contains(where: { $0.rawValue == t.rawValue }) else {
            throw SettingsError("\(k) must be one of: \(options.map(\.rawValue).joined(separator: ", ")).")
        }
        return t
    }

    static func chat(_ args: JSON) throws -> ChatSettingsChange {
        let o = try object(args, "The arguments")
        try onlyKnown(o, chatKeys, "")
        var c = ChatSettingsChange()
        for s in ChatSettingsChange.Switch.allCases { if let v = try bool(o, s.rawValue) { c.switches[s] = v } }
        c.autoSend = try bool(o, "auto_send")
        if c.autoSend == true && c.switches[.send] == false {
            throw SettingsError("Auto-send needs Send turned on, so \"auto_send\": true can't go with \"send\": false. Nothing was changed.")
        }
        if let f = o["filter"] {
            let fo = try object(f, "filter")
            try onlyKnown(fo, filterKeys, " in filter")
            c.filterOn = try bool(fo, "on")
            c.strictness = try choice(fo, "strictness", FilterStrictness.self, FilterStrictness.allCases)
            c.photoMode = try choice(fo, "photos", PhotoMode.self, PhotoMode.allCases)
            if let cats = fo["categories"] {
                let co = try object(cats, "filter.categories")
                try onlyKnown(co, FilterCategory.allCases.map(\.mcpName), " in filter.categories")
                for (k, v) in co {
                    let cat = FilterCategory(mcpName: k)!
                    guard let s = v.string, let a = FilterAction(rawValue: s), cat.choices.contains(a) else {
                        throw SettingsError("filter.categories.\(k) must be one of: \(cat.choices.map(\.rawValue).joined(separator: ", ")).")
                    }
                    c.actions[cat] = a
                }
            }
        }
        guard c != ChatSettingsChange() else { throw SettingsError("Include at least one setting to change.") }
        return c
    }

    static func app(_ args: JSON) throws -> AppSettingsChange {
        let o = try object(args, "The arguments")
        try onlyKnown(o, appKeys, "")
        var c = AppSettingsChange()
        c.paused = try bool(o, "paused")
        c.newMessagePings = try bool(o, "new_message_pings")
        c.pingWhenIReply = try bool(o, "ping_when_i_reply")
        c.autoSendAllowed = try bool(o, "auto_send")
        if let n = o["assistant_name"] {
            guard let s = n.string else { throw SettingsError("assistant_name must be text.") }
            c.assistantName = try assistantName(s)
        }
        if let l = o["auto_send_limit"] {
            let lo = try object(l, "auto_send_limit")
            try onlyKnown(lo, limitKeys, " in auto_send_limit")
            func whole(_ v: JSON?) -> Int? {
                guard case .number(let n)? = v, n == n.rounded(), abs(n) < 1e9 else { return nil }
                return Int(n)
            }
            guard let count = whole(lo["count"]), let minutes = whole(lo["minutes"]) else {
                throw SettingsError("auto_send_limit needs whole numbers for both count and minutes.")
            }
            guard AutoSendLimit.counts.contains(count), AutoSendLimit.minuteRange.contains(minutes) else {
                throw SettingsError("auto_send_limit: count must be \(AutoSendLimit.counts.lowerBound)–\(AutoSendLimit.counts.upperBound) and minutes \(AutoSendLimit.minuteRange.lowerBound)–\(AutoSendLimit.minuteRange.upperBound).")
            }
            c.autoSendLimit = AutoSendLimit(count: count, minutes: minutes)
        }
        guard c != AppSettingsChange() else { throw SettingsError("Include at least one setting to change.") }
        return c
    }

    /// The assistant picks this name, and the app shows it in prompts, so it's held to strict rules
    /// instead of being cleaned up silently: plain printable text, short, and not posing as the user or Veil.
    static func assistantName(_ raw: String) throws -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let bad = s.unicodeScalars.contains { u in
            let cat = u.properties.generalCategory
            return cat == .control || cat == .format || cat == .lineSeparator || cat == .paragraphSeparator
                || (u.properties.isWhitespace && u != " ")
        }
        guard !s.isEmpty, s.count <= 30, !bad else {
            throw SettingsError("assistant_name must be 1–30 characters of plain text on one line.")
        }
        let lower = s.lowercased()
        let reserved = ["you", "me", "user", "owner", "unknown assistant", "apple", "macos", "system", "messages"]
        guard !reserved.contains(lower), !lower.contains("veil") else {
            throw SettingsError("That assistant_name isn't allowed. Pick a name that doesn't look like you, Veil or the system.")
        }
        return s
    }
}
