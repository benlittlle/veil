import Foundation

/// Minimal JSON value used for MCP messages and tool payloads.
public enum JSON: Codable, Equatable, Sendable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                  ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    case string(String), number(Double), bool(Bool), array([JSON]), object([String: JSON]), null

    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .number(Double(v)) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral v: JSON...) { self = .array(v) }
    public init(dictionaryLiteral v: (String, JSON)...) { self = .object(Dictionary(v, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
    public init(_ v: String?) { self = v.map { .string($0) } ?? .null }
    public init(_ v: Int64) { self = .number(Double(v)) }
    public init(_ v: Int) { self = .number(Double(v)) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    public subscript(key: String) -> JSON? { if case .object(let o) = self { return o[key] }; return nil }
    public var objectKeys: [String] { if case .object(let o) = self { return Array(o.keys) }; return [] }
    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var int: Int? { if case .number(let n) = self { return Int(exactly: n.rounded()) }; if case .string(let s) = self { return Int(s) }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var array: [JSON]? { if case .array(let a) = self { return a }; return nil }

    public func encoded(pretty: Bool = false) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? e.encode(self)) ?? Data("null".utf8), as: UTF8.self)
    }

    /// Deeper input is refused before decoding. Decoding recurses once per level, and the threads that
    /// serve connections have small stacks, so a short line of brackets could otherwise crash Veil.
    /// MCP messages are a handful of levels deep.
    public static let maxDepth = 64

    public static func parse(_ data: Data) -> JSON? {
        guard withinDepth(data, maxDepth) else { return nil }
        return try? JSONDecoder().decode(JSON.self, from: data)
    }

    /// True when arrays and objects nest at most `limit` levels (brackets inside strings don't count).
    static func withinDepth(_ data: Data, _ limit: Int) -> Bool {
        var depth = 0, inString = false, escaped = false
        for b in data {
            if inString {
                if escaped { escaped = false } else if b == 0x5C { escaped = true } else if b == 0x22 { inString = false }
                continue
            }
            switch b {
            case 0x22: inString = true
            case 0x5B, 0x7B: depth += 1; if depth > limit { return false }
            case 0x5D, 0x7D: depth -= 1
            default: break
            }
        }
        return true
    }
}
