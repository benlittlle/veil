import Foundation

// Deterministic detectors for the content filter. Pure Swift, no dependencies, no model.
// Each returns the exact span to mask, so the rest of the message survives.
//
// They are tuned to miss as little as possible while staying quiet on ordinary numbers,
// dates, times, prices and phone numbers. They are a risk reduction, not a guarantee.

public struct Detection: Equatable, Sendable {
    public let category: FilterCategory
    public let range: Range<String.Index>
}

public enum Detectors {
    /// Every sensitive span in `text`, in order. Overlaps are allowed; masking merges them.
    public static func scan(_ text: String) -> [Detection] {
        guard !text.isEmpty else { return [] }
        var out: [Detection] = []
        out += cards(text)
        out += codes(text)
        out += bank(text)
        out += ids(text)
        out += secrets(text)
        out += profanity(text)
        return out.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: Card numbers

    private static let cardPattern = re(#"(?<![\d+])(?:\d[ \-]?){12,18}\d(?!\d)"#)

    static func cards(_ text: String) -> [Detection] {
        matches(cardPattern, text).compactMap { r in
            let digits = text[r].compactMap(\.wholeNumberValue)
            guard (13...19).contains(digits.count), luhn(digits), plausibleCardPrefix(digits) else { return nil }
            // Grouped numbers must use one separator style (4-4-4-4, 4 6 5, ...), never mixed like a phone number.
            let seps = Set(text[r].filter { $0 == " " || $0 == "-" })
            guard seps.count <= 1 else { return nil }
            return Detection(category: .cardNumbers, range: r)
        }
    }

    public static func luhn(_ digits: [Int]) -> Bool {
        guard digits.count >= 2 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    /// Card networks start with 2–6 (Mastercard 2-series, Amex/Diners/JCB 3, Visa 4, Mastercard/Maestro 5, Discover/UnionPay 6).
    private static func plausibleCardPrefix(_ d: [Int]) -> Bool {
        guard let first = d.first else { return false }
        if first == 2 {
            let p4 = d.prefix(4).reduce(0) { $0 * 10 + $1 }
            return (2221...2720).contains(p4)
        }
        return (3...6).contains(first)
    }

    // MARK: PINs, one-time and verification codes (contextual)

    /// 4–8 digits (or 3+3), not part of a longer number, price, time, decimal or percentage.
    private static let codeNumber = #"(?<![\d£$€#])(?<!\d[.,:/])(\d{4,8}|\d{3}[ \-]\d{3})(?!\d|[.,:/]\d|%)"#
    private static let codeKeyword = #"(?:(?:verification|verify|security|confirmation|login|log-?in|sign[- ]?in|auth(?:entication|orization)?|access|one[- ]time|2fa|two[- ]factor|reset|activation|recovery|bank)\s+(?:code|pin|passcode|number)|\bcode\b|\bpin(?:\s*(?:code|number|no\.?))?\b|\bpasscode\b|\botp\b|\b2fa\b|\bcvv2?\b|\bcvc\b)"#
    /// "code is 4417", "PIN: 1234", "OTP 845 221", "verification code - 123456", "PIN for the door is 2468"
    private static let codeAfter = re(codeKeyword + #"(?:\s+(?:for|to|of|on)\s+(?:the\s+|my\s+|your\s+|our\s+)?[\w'-]{1,20}){0,2}\s*(?:#|no\.?|number)?\s*(?:is|was|=|:|-|–)?\s*(?:now\s+)?"# + codeNumber, caseInsensitive: true)
    /// "123456 is your verification code", "G-123456 is your Google code"
    private static let codeBefore = re(#"(?<![\d\w])(?:[A-Z]-)?"# + codeNumber + #"\s+(?:is|=)\s+(?:your|the)\b[^.\n]{0,40}?\b(?:code|pin|passcode|otp)\b"#, caseInsensitive: true)
    /// "Use 123456 to verify", "enter 4417 to sign in"
    private static let codeUse = re(#"\b(?:use|enter|type)\s+(?:code\s+)?"# + codeNumber + #"\s+(?:to|as|for)\s+(?:verify|log|sign|confirm|reset|complete|access|continue|authori[sz]e|your)"#, caseInsensitive: true)

    static func codes(_ text: String) -> [Detection] {
        var out: [Detection] = []
        for p in [codeAfter, codeBefore, codeUse] {
            for m in p.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let r = Range(m.range(at: 1), in: text) else { continue }
                out.append(Detection(category: .codes, range: r))
            }
        }
        return out
    }

    // MARK: Bank details

    private static let sortCodeContext = re(#"\b(?:sort\s*code|s/c)\b\s*(?:is|:|-|=)?\s*(\d{2}[ \-]?\d{2}[ \-]?\d{2})(?!\d)"#, caseInsensitive: true)
    /// A sort code followed by an 8-digit account number, even without labels: "20-00-00 12345678".
    private static let sortAndAccount = re(#"(?<![\d\-])(\d{2}-\d{2}-\d{2}[ ,/]+\d{8})(?!\d)"#)
    private static let accountContext = re(#"\b(?:account|acct|a/c|acc)\.?\s*(?:number|no\.?|num|#)?\s*(?:is|:|-|=)?\s*(\d[\d ]{4,18}\d)(?!\d)"#, caseInsensitive: true)
    private static let routingContext = re(#"\b(?:routing|aba|rtn)\s*(?:number|no\.?|num|#)?\s*(?:is|:|-|=)?\s*(\d{9})(?!\d)"#, caseInsensitive: true)
    private static let ibanPattern = re(#"\b([A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30})\b"#)

    static func bank(_ text: String) -> [Detection] {
        var out: [Detection] = []
        for p in [sortCodeContext, sortAndAccount, accountContext] {
            for r in groups(p, text) { out.append(Detection(category: .bankDetails, range: r)) }
        }
        for r in groups(routingContext, text) where abaValid(text[r].compactMap(\.wholeNumberValue)) {
            out.append(Detection(category: .bankDetails, range: r))
        }
        for r in groups(ibanPattern, text) {
            // Trim trailing chunks until the checksum passes (the pattern can over-reach into the next word).
            var candidate = r
            while true {
                let compact = text[candidate].filter { $0 != " " }
                if compact.count >= 15, ibanValid(String(compact)) { out.append(Detection(category: .bankDetails, range: candidate)); break }
                guard compact.count > 15, let last = text[candidate].lastIndex(where: { $0 != " " }) else { break }
                var end = last
                // Drop one character (and any space before it).
                while end > candidate.lowerBound, text[text.index(before: end)] == " " { end = text.index(before: end) }
                candidate = candidate.lowerBound..<end
            }
        }
        return out
    }

    /// ISO 13616 mod-97 check.
    public static func ibanValid(_ raw: String) -> Bool {
        let s = raw.uppercased().filter { $0 != " " }
        guard (15...34).contains(s.count), s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              s.prefix(2).allSatisfy(\.isLetter), s.dropFirst(2).prefix(2).allSatisfy(\.isNumber) else { return false }
        let rearranged = s.dropFirst(4) + s.prefix(4)
        var rem = 0
        for ch in rearranged {
            if let d = ch.wholeNumberValue { rem = (rem * 10 + d) % 97 }
            else if let a = ch.asciiValue { let v = Int(a) - 55; rem = (rem * 100 + v) % 97 }
            else { return false }
        }
        return rem == 1
    }

    /// ABA routing number checksum.
    public static func abaValid(_ d: [Int]) -> Bool {
        guard d.count == 9, d.contains(where: { $0 != 0 }) else { return false }
        return (3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])) % 10 == 0
    }

    // MARK: Government IDs

    /// UK National Insurance: two letters (with exclusions), six digits, A–D.
    /// Written either compact (AB123456C) or fully spaced (AB 12 34 56 C), not a mix like a flight number.
    private static let niPattern = re(#"(?<![A-Za-z0-9])((?!BG|GB|KN|NK|NT|TN|ZZ)[A-CEGHJ-PR-TW-Z][A-CEGHJ-NPR-TW-Z](?:\d{6}|\ \d{2}\ \d{2}\ \d{2}\ )[A-D])(?![A-Za-z0-9])"#, caseInsensitive: true)
    /// US SSN with separators, excluding impossible ranges.
    private static let ssnPattern = re(#"(?<![\d\-])((?!000|666|9\d\d)\d{3}([\- ])(?!00)\d{2}\2(?!0000)\d{4})(?![\d\-])"#)
    private static let ssnContext = re(#"\b(?:ssn|social\s+security(?:\s+(?:number|no\.?))?)\s*(?:is|:|#|-)?\s*(\d{9}|\d{3}[\- ]\d{2}[\- ]\d{4})(?!\d)"#, caseInsensitive: true)
    private static let passportContext = re(#"\bpassport\s*(?:number|no\.?|num|#)?\s*(?:is|:|-|=)?\s*([A-Z0-9]{6,9})\b"#, caseInsensitive: true)
    private static let licenceContext = re(#"\b(?:driving\s+licen[cs]e|driver'?s\s+licen[cs]e|dl)\s*(?:number|no\.?|#)?\s*(?:is|:|-|=)?\s*([A-Z0-9]{6,18})\b"#, caseInsensitive: true)

    static func ids(_ text: String) -> [Detection] {
        var out: [Detection] = []
        for p in [niPattern, ssnPattern, ssnContext] {
            for r in groups(p, text) { out.append(Detection(category: .governmentIDs, range: r)) }
        }
        for p in [passportContext, licenceContext] {
            for r in groups(p, text) where text[r].contains(where: \.isNumber) {
                out.append(Detection(category: .governmentIDs, range: r))
            }
        }
        return out
    }

    // MARK: Passwords, keys, tokens

    private static let passwordContext = re(#"\b(?:password|passwd|pwd|pw|passphrase|pass\s*word|wi-?fi\s*(?:password|pw|key|code)|pass(?=\s*:))\s*(?:is|was|:|=|-|–)\s*(?:now\s+)?["'“‘]?([^\s"'”’]{3,})"#, caseInsensitive: true)
    private static let keyContext = re(#"\b(?:api[\s_-]?key|secret(?:[\s_-]?key)?|access[\s_-]?key|token|bearer|private[\s_-]?key|client[\s_-]?secret|recovery\s+(?:key|phrase)|seed\s+phrase)\s*(?:is|:|=|-)?\s*["'“‘]?([A-Za-z0-9_\-+/=.]{12,})"#, caseInsensitive: true)
    private static let knownKeys = re(#"(?<![A-Za-z0-9])((?:sk|pk|rk)[-_](?:live|test|proj|ant)?[-_]?[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abprs]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{35}|eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$))"#)
    private static let longToken = re(#"(?<![A-Za-z0-9_\-+/=])([A-Za-z0-9_\-+/=]{24,})(?![A-Za-z0-9_\-+/=])"#)

    static func secrets(_ text: String) -> [Detection] {
        var out: [Detection] = []
        for p in [passwordContext, knownKeys] {
            for r in groups(p, text) { out.append(Detection(category: .secrets, range: r)) }
        }
        // "token appreciation" isn't a key: labelled keys must contain a digit.
        for r in groups(keyContext, text) where text[r].contains(where: \.isNumber) {
            out.append(Detection(category: .secrets, range: r))
        }
        for r in groups(longToken, text) where looksRandom(text[r]) {
            out.append(Detection(category: .secrets, range: r))
        }
        return out
    }

    /// Long strings mixing upper case, lower case and digits with high character entropy.
    static func looksRandom(_ s: Substring) -> Bool {
        guard s.count >= 24, s.contains(where: \.isUppercase), s.contains(where: \.isLowercase), s.contains(where: \.isNumber) else { return false }
        var freq: [Character: Double] = [:]
        for c in s { freq[c, default: 0] += 1 }
        let n = Double(s.count)
        let entropy = freq.values.reduce(0) { $0 - ($1 / n) * log2($1 / n) }
        return entropy >= 3.5
    }

    // MARK: Profanity

    /// Whole words only, so "Scunthorpe", "class" or "cocktail" never match.
    private static let swearPattern = re(#"\b(?:motherfuck\w*|fuck\w*|f\*ck\w*|bullshit\w*|shit(?:s|ty|ting|ted|head|hole|e)?|cunts?|bitch(?:es|ing|y)?|bastards?|assholes?|arseholes?|arse|wank(?:er|ers|ing)?|twats?|pricks?|dickheads?|bollocks|piss(?:\s+off)?|crap)\b"#, caseInsensitive: true)

    static func profanity(_ text: String) -> [Detection] {
        matches(swearPattern, text).map { Detection(category: .profanity, range: $0) }
    }

    /// "fuck" → "f***". Keeps the first letter so the tone survives without the word.
    public static func maskSwear(_ word: Substring) -> String {
        guard let first = word.first else { return "" }
        return String(first) + "***"
    }

    // MARK: Helpers

    private static func re(_ p: String, caseInsensitive: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    private static func matches(_ re: NSRegularExpression, _ text: String) -> [Range<String.Index>] {
        re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    /// The first capture group of each match.
    private static func groups(_ re: NSRegularExpression, _ text: String) -> [Range<String.Index>] {
        re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            $0.numberOfRanges > 1 ? Range($0.range(at: 1), in: text) : nil
        }
    }
}
