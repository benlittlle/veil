import Foundation

// Content-filter settings. These live inside the signed permissions.json (see ChatAccess and
// PermissionState) and are changed only by the app UI. No MCP tool can read or change them.

/// Something the content filter looks for.
public enum FilterCategory: String, Codable, CaseIterable, Sendable, Comparable, Identifiable {
    // Found by deterministic detectors (pattern matching on this Mac, no model).
    case cardNumbers, codes, bankDetails, governmentIDs, secrets, profanity
    // Judged by the on-device language model.
    case politics, health, sexual, conflict, moneyWorries
    // Seen in photos by the on-device model (photos & files set to Check).
    case idDocuments, paymentCards, personalDocuments, privateScreenshots, nudity

    public var id: String { rawValue }

    public enum Kind: Sendable { case pattern, judgement, photo }

    public var kind: Kind {
        switch self {
        case .cardNumbers, .codes, .bankDetails, .governmentIDs, .secrets, .profanity: return .pattern
        case .politics, .health, .sexual, .conflict, .moneyWorries: return .judgement
        case .idDocuments, .paymentCards, .personalDocuments, .privateScreenshots, .nudity: return .photo
        }
    }

    /// True for the categories the language model judges in message text.
    public var usesModel: Bool { kind == .judgement }

    /// The choices that make sense for this category.
    public var choices: [FilterAction] {
        if kind != .pattern { return [.allow, .withhold] }
        if self == .profanity { return [.allow, .mask] }
        return [.allow, .mask, .withhold]
    }

    public static var detectorCategories: [FilterCategory] { allCases.filter { $0.kind == .pattern } }
    public static var modelCategories: [FilterCategory] { allCases.filter { $0.kind == .judgement } }
    public static var photoCategories: [FilterCategory] { allCases.filter { $0.kind == .photo } }

    public var title: String {
        switch self {
        case .cardNumbers: return "Card numbers"
        case .codes: return "PINs & verification codes"
        case .bankDetails: return "Bank details"
        case .governmentIDs: return "ID numbers"
        case .secrets: return "Passwords & keys"
        case .profanity: return "Swearing"
        case .politics: return "Politics"
        case .health: return "Health & medical"
        case .sexual: return "Sexual content"
        case .conflict: return "Arguments & insults"
        case .moneyWorries: return "Money worries"
        case .idDocuments: return "ID documents"
        case .paymentCards: return "Bank & payment cards"
        case .personalDocuments: return "Letters & documents"
        case .privateScreenshots: return "Private screenshots"
        case .nudity: return "Nudity"
        }
    }

    public var detail: String {
        switch self {
        case .cardNumbers: return "13–19 digit card numbers that pass the card checksum."
        case .codes: return "PINs, one-time and verification codes."
        case .bankDetails: return "Sort codes, account and routing numbers, IBANs."
        case .governmentIDs: return "National Insurance, Social Security and passport numbers."
        case .secrets: return "Passwords, API keys, tokens and long random strings."
        case .profanity: return "Swear words are shown as f***."
        case .politics: return "Political opinions, especially harsh ones."
        case .health: return "Health, medical and mental-health details."
        case .sexual: return "Sexual or explicit content."
        case .conflict: return "Heated arguments, insults and personal attacks."
        case .moneyWorries: return "Debt, struggling to pay, financial stress."
        case .idDocuments: return "Passports, driving licences and ID cards."
        case .paymentCards: return "Photos of bank, credit and debit cards."
        case .personalDocuments: return "Letters, bills, statements and forms with personal or financial details."
        case .privateScreenshots: return "Screenshots of chats, email or apps showing private details or codes."
        case .nudity: return "Nudity and sexual images."
        }
    }

    public static func < (a: FilterCategory, b: FilterCategory) -> Bool {
        allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
    }
}

/// What happens when a category is found.
public enum FilterAction: String, Codable, Sendable, CaseIterable {
    /// Leave it alone.
    case allow
    /// Replace just the matched part ("[removed]", or "f***" for swearing).
    case mask
    /// Replace the whole message with "[withheld]".
    case withhold

    public var title: String {
        switch self { case .allow: return "Allow"; case .mask: return "Mask"; case .withhold: return "Withhold" }
    }
}

/// How sure the model has to be before a judgement category withholds a message.
/// "Unsure" answers always withhold, whatever the strictness.
public enum FilterStrictness: String, Codable, Sendable, CaseIterable {
    case relaxed, balanced, strict

    public var title: String {
        switch self { case .relaxed: return "Relaxed"; case .balanced: return "Balanced"; case .strict: return "Strict" }
    }
    public var detail: String {
        switch self {
        case .relaxed: return "Withholds only clear-cut, strong cases."
        case .balanced: return "Withholds clear cases."
        case .strict: return "Withholds even mild or passing mentions."
        }
    }
    /// The lowest level that withholds.
    var threshold: ConcernLevel {
        switch self { case .relaxed: return .strong; case .balanced: return .clear; case .strict: return .mild }
    }
}

/// What happens to photos & files in a filtered chat.
public enum PhotoMode: String, Codable, Sendable, CaseIterable {
    /// Shared unchecked (file names are still masked).
    case allow
    /// Each photo is checked on this Mac and shared only if it's clean. Other files are withheld.
    case check
    /// Nothing is shared.
    case withhold

    public var title: String {
        switch self { case .allow: return "Allow"; case .check: return "Check"; case .withhold: return "Withhold" }
    }
}

/// One filter profile: an action per category, a strictness for the model, and what to do with photos & files.
public struct FilterPolicy: Codable, Equatable, Sendable {
    /// Keyed by `FilterCategory.rawValue`. Missing or unsuitable entries fall back to the standard action.
    public private(set) var actions: [String: FilterAction]
    public var strictness: FilterStrictness
    /// Photos and files in filtered chats. Stored as "allow", "check" or "withhold"; files from
    /// before Check existed hold "allow" or "withhold" and decode unchanged.
    public var attachments: PhotoMode

    public init(actions: [FilterCategory: FilterAction] = [:], strictness: FilterStrictness = .balanced,
                attachments: PhotoMode = .check) {
        var all: [String: FilterAction] = [:]
        for c in FilterCategory.allCases { all[c.rawValue] = Self.standardAction(c) }
        for (c, a) in actions where c.choices.contains(a) { all[c.rawValue] = a }
        self.actions = all
        self.strictness = strictness
        self.attachments = attachments
    }

    public func action(_ c: FilterCategory) -> FilterAction {
        guard let a = actions[c.rawValue], c.choices.contains(a) else { return Self.standardAction(c) }
        return a
    }

    public mutating func set(_ c: FilterCategory, _ a: FilterAction) {
        guard c.choices.contains(a) else { return }
        actions[c.rawValue] = a
    }

    /// Any judgement category that isn't Allow needs the model to clear each message.
    public var needsModel: Bool { FilterCategory.modelCategories.contains { action($0) != .allow } }
    /// Photos & files can reach the assistant at all (Allow, or Check for photos that pass).
    public var attachmentsShared: Bool { attachments != .withhold }

    /// A short stable fingerprint of these settings (for the user's review screen and diagnostics).
    public var fingerprint: String {
        let parts = FilterCategory.allCases.map { "\($0.rawValue)=\(action($0).rawValue)" }
        return (parts + ["strictness=\(strictness.rawValue)", "attachments=\(attachments.rawValue)"]).joined(separator: ";")
    }

    /// Standard profile: mask detector finds, withhold judgement and photo categories, check photos.
    public static func standardAction(_ c: FilterCategory) -> FilterAction { c.kind == .pattern ? .mask : .withhold }
    public static let standard = FilterPolicy()

    private enum CodingKeys: String, CodingKey { case actions, strictness, attachments }
    // Decoded exactly as stored (unknown or missing categories are kept as they are and fall
    // back to the standard action when read), so re-encoding gives the same signed bytes even
    // across versions that add categories.
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        actions = try c.decode([String: FilterAction].self, forKey: .actions)
        strictness = try c.decode(FilterStrictness.self, forKey: .strictness)
        attachments = try c.decode(PhotoMode.self, forKey: .attachments)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(actions, forKey: .actions)
        try c.encode(strictness, forKey: .strictness)
        try c.encode(attachments, forKey: .attachments)
    }
}
