import Foundation

// Deterministic detectors for the content filter. Pure Swift, no dependencies, no model.
// Each returns the exact span to mask, so the rest of the message survives.
//
// They are tuned to miss as little as possible while staying quiet on ordinary numbers,
// dates, times, prices and phone numbers. They are a risk reduction, not a guarantee.
//
// Text is normalised before scanning (invisible formatting characters removed, Unicode spaces
// folded, NFKC, look-alike Cyrillic/Greek letters folded inside Latin words), and every match is
// mapped back to the whole characters it came from in the original text.

public struct Detection: Equatable, Sendable {
    public let category: FilterCategory
    public let range: Range<String.Index>
}

public enum Detectors {
    /// Every sensitive span in `text`, in order. Overlaps are allowed; masking merges them.
    public static func scan(_ text: String) -> [Detection] {
        guard !text.isEmpty else { return [] }
        let n = Normalized(text)
        let t = n.text
        var out: [Detection] = []
        out += cards(t)
        out += codes(t)
        out += bank(t)
        out += ids(t)
        out += secrets(t)
        out += profanity(t)
        return out.compactMap { d in n.original(d.range).map { Detection(category: d.category, range: $0) } }
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    // MARK: Card numbers

    /// 13–23 digits with optional separators between any two of them: one space or hyphen (the common
    /// forms), a dot or slash, a run of spaces, " - ", or a line break. Room for a trailing CVV or expiry,
    /// which `cardCandidate` drops before checking for a 13–19 digit card.
    private static let cardPattern = re(#"(?<![\d+])\d(?:(?:[ \-./]|\ {2,3}|\ ?[\-./]\ ?|[ \t]*\n[ \t]*)?\d){12,22}(?!\d)"#)
    /// Words that make a long checksum-valid number something other than a card: "IMEI 35…", "Order 302-…".
    private static let notACard = re(#"\b(?:imei|meid|esn|iccid|order|tracking|track|serial|s/n|invoice|ref|reference|awb|booking|ticket|parcel|shipment|consignment)\b\.?(?:\s*(?:no\.?|number|num|id|#))?\s*[:#]?\s*$"#, caseInsensitive: true)

    static func cards(_ text: String) -> [Detection] {
        matches(cardPattern, text).compactMap { r in
            // A number right after "IMEI", "order", "tracking"… isn't treated as a card.
            let before = text[text.index(r.lowerBound, offsetBy: -min(40, text.distance(from: text.startIndex, to: r.lowerBound)))..<r.lowerBound]
            if !matches(notACard, String(before)).isEmpty { return nil }
            return cardCandidate(text, r).map { Detection(category: .cardNumbers, range: $0) }
        }
    }

    /// The longest valid card in a match, dropping trailing groups that don't belong (a CVV, an expiry).
    private static func cardCandidate(_ text: String, _ r: Range<String.Index>) -> Range<String.Index>? {
        // Split into digit groups with the separator before each.
        var groups: [(range: Range<String.Index>, sep: String)] = []
        var i = r.lowerBound, sep = ""
        while i < r.upperBound {
            if isDigit(text[i]) {
                var j = i
                while j < r.upperBound, isDigit(text[j]) { j = text.index(after: j) }
                groups.append((i..<j, sep)); sep = ""; i = j
            } else { sep.append(text[i]); i = text.index(after: i) }
        }
        var count = groups.count
        while count >= 1 {
            let span = groups[0].range.lowerBound..<groups[count - 1].range.upperBound
            let digits = digitValues(text[span])
            if digits.count < 13 { return nil }
            if digits.count <= 19, luhn(digits), plausibleCardPrefix(digits), consistent(Array(groups[0..<count]), text) { return span }
            count -= 1
        }
        return nil
    }

    /// One separator style throughout (4-4-4-4, 4 6 5, 4.4.4.4…), never mixed like a phone number.
    /// A line break goes with any style. Dots, slashes and line breaks need card-like groups of 3–6 digits.
    private static func consistent(_ groups: [(range: Range<String.Index>, sep: String)], _ text: String) -> Bool {
        guard groups.count > 1 else { return true }
        var styles = Set<String>(), strict = false
        for g in groups.dropFirst() {
            if g.sep.contains("\n") { strict = true; continue }
            let s = g.sep.trimmingCharacters(in: .whitespaces)
            styles.insert(s.isEmpty ? " " : s)
            if s == "." || s == "/" { strict = true }
        }
        guard styles.count <= 1 else { return false }
        if strict, groups.dropLast().contains(where: { !(3...6).contains(text[$0.range].count) }) { return false }
        return true
    }

    /// A decimal digit, even with a mark attached ("1\u{301}" is one character).
    private static func isDigit(_ c: Character) -> Bool { c.unicodeScalars.first?.properties.generalCategory == .decimalNumber }
    private static func digitValues(_ s: Substring) -> [Int] {
        s.unicodeScalars.compactMap { $0.properties.generalCategory == .decimalNumber ? $0.properties.numericValue.map { Int($0) } : nil }
    }

    public static func luhn(_ digits: [Int]) -> Bool {
        guard digits.count >= 2 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    /// Card networks: Mir (2200–2204), Mastercard 2-series (2221–2720), Amex/Diners/JCB 3, Visa 4,
    /// Mastercard/Maestro 5, Discover/UnionPay/RuPay 6, RuPay 81–82, Troy 9792.
    private static func plausibleCardPrefix(_ d: [Int]) -> Bool {
        guard let first = d.first else { return false }
        let p4 = d.prefix(4).reduce(0) { $0 * 10 + $1 }
        switch first {
        case 2: return (2200...2204).contains(p4) || (2221...2720).contains(p4)
        case 3...6: return true
        case 8: return d.count > 1 && (d[1] == 1 || d[1] == 2)
        case 9: return p4 == 9792
        default: return false
        }
    }

    // MARK: PINs, one-time and verification codes (contextual)

    /// 4–8 digits (or 3+3), not part of a longer number, price, time, decimal or percentage.
    private static let codeNumber = #"(?<![\d£$€#])(?<!\d[.,:/])(\d{4,8}|\d{3}[ \-]\d{3})(?!\d|[.,:/]\d|%)"#
    /// The value after a code keyword: also "#4417", "G-845221" (the prefix stays) and spaced digits "8 4 5 2 2 1".
    private static let codeValue = #"#?(?:(?-i:[A-Z]{1,3})-)?(?<![\d£$€])(?<!\d[.,:/])(\d{4,8}|\d{3}[ \-]\d{3}|\d(?:[ \-]\d){3,7})(?!\d|[.,:/]\d|%)"#
    /// Kinds of "code" that aren't secret: zip code 90210, area code 0161, promo code 2024, error code 404…
    private static let notSecretCode = #"(?<!\b(?:zip|area|post|postal|promo|promotional|discount|coupon|referral|error|dress|country|source|qr|bar|status|exit|response|http|colou?r|airport|airline|tax|product|course|dialling|dialing|calling|region|language|currency|iso|program|programme|machine|morse|cheat|zone|station|stock|item|class)[\s\-]{1,2})"#
    private static let codeKeyword = #"(?:(?:verification|verify|security|confirmation|login|log-?in|sign[- ]?in|auth(?:entication|orization)?|access|one[- ]time|2fa|two[- ]factor|reset|activation|recovery|bank)\s+(?:code|pin|passcode|number)|"# + notSecretCode + #"\bcode\b|\bpin(?:\s*(?:code|number|no\.?))?\b|\bpasscode\b|\botp\b|\b2fa\b|\bcvv2?\b|\bcvc\b)"#
    /// "code is 4417", "PIN: 1234", "OTP 845 221", "verification code - 123456", "PIN for the door is 2468", "PIN #2468"
    private static let codeAfter = re(codeKeyword + #"(?:\s+(?:for|to|of|on)\s+(?:the\s+|my\s+|your\s+|our\s+)?[\w'-]{1,20}){0,2}\s*(?:#|no\.?|number)?\s*(?:is|was|=|:|-|–)?\s*(?:now\s+)?"# + codeValue, caseInsensitive: true)
    /// "123456 is your verification code", "G-123456 is your Google code", "845221 - your verification code"
    private static let codeBefore = re(#"(?<![\d\w])(?:[A-Z]-)?"# + codeNumber + #"(?:\s+(?:is|=)\s+|\s*[-–—:|]\s*)(?:your|the)\b[^.\n]{0,40}?\b"# + notSecretCode + #"(?:code|pin|passcode|otp)\b"#, caseInsensitive: true)
    /// "Use 123456 to verify", "enter 4417 to sign in", "Enter 845221 on the sign-in page"
    private static let codeUse = re(#"\b(?:use|enter|type)\s+(?:code\s+)?"# + codeNumber + #"\s+(?:(?:to|as|for)\s+(?:verify|log|sign|confirm|reset|complete|access|continue|authori[sz]e|your)|(?:on|in|at|into)\s+(?:the\s+|your\s+)?(?:[\w-]+\s+){0,2}?(?:page|app|screen|site|website|field|box|prompt|form))"#, caseInsensitive: true)
    /// Letter-and-digit codes after a clear code phrase: "Your code is A7K9Q2", "Steam Guard code: 7FKX2".
    private static let codeAlnum = re(#"(?:\b(?:verification|verify|security|confirmation|login|log-?in|sign[- ]?in|auth(?:entication|orization)?|access|one[- ]time|2fa|two[- ]factor|reset|activation|recovery|guard|backup|your|my|the)\s+(?:[\w-]+\s+){0,2}?"# + notSecretCode + #"code\b|\b(?:otp|passcode)\b)\s*(?:is|was|=|:|-|–)\s*(?:now\s+)?(?:(?-i:[A-Z]{1,3})-)?((?-i:(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{4,8}))(?![A-Za-z0-9])"#, caseInsensitive: true)
    /// Card security codes are three digits (four for Amex): "CVV 123", "security code: 789".
    private static let cardSecurityCode = re(#"\b(?:cvv2?|cvc2?|csc|card\s+security\s+code|security\s+code)\b\s*(?:#|no\.?|number)?\s*(?:is|was|=|:|-|–)?\s*(\d{3,4})(?!\d)"#, caseInsensitive: true)

    /// Code words in Spanish, Portuguese, French, German, Italian, Chinese and Japanese.
    private static let intlCodeKeyword = #"(?:\b(?:c[oó]digo(?:\s+(?:de\s+)?(?:verificaci[oó]n|verifica[cç][aã]o|seguridad|seguran[cç]a|acceso|acesso|confirmaci[oó]n|confirma[cç][aã]o|activaci[oó]n|ativa[cç][aã]o|autenticaci[oó]n|autentica[cç][aã]o|un\s+solo\s+uso|uso\s+[uú]nico))?|clave(?:\s+(?:de\s+)?(?:acceso|verificaci[oó]n|seguridad|din[aá]mica))?|"# + notSecretCode + #"code(?:\s+(?:de\s+)?(?:v[eé]rification|s[eé]curit[eé]|confirmation|connexion|validation|d['’]acc[eè]s|d['’]activation))?|(?:best[aä]tigungs|sicherheits|verifizierungs|verifikations|zugangs|anmelde|einmal|aktivierungs|freigabe|login|sms)-?code|codice(?:\s+(?:di\s+)?(?:verifica|sicurezza|accesso|conferma|attivazione|otp))?|(?-i:(?:m|SMS-|push)?TAN))\b|验证码|驗證碼|校验码|校驗碼|动态码|動態碼|确认码|確認碼|安全码|安全碼|动态密码|動態密碼|认证码|認證碼|認証コード|確認コード|認証番号|確認番号|ワンタイムパスワード|セキュリティコード|暗証番号|パスコード|検証コード)"#
    private static let intlCodeAfter = re(intlCodeKeyword + #"\s*(?:(?:es|est|ist|lautet|é|è|e'|是|为|為|は|:|=|-|–)\s*){0,2}[\[【「(]?\s*"# + codeValue, caseInsensitive: true)
    /// "845221 es tu código", "845221 est votre code", "845221 ist dein Code", "845221 é o seu código", "845221 è il tuo codice"
    private static let intlCodeBefore = re(#"(?<![\d\w])"# + codeNumber + #"\s+(?:es|est|ist|é|è)\s+(?:tu|su|votre|ton|dein|ihr|o\s+(?:seu|teu)|il\s+(?:tuo|suo))\b[^.\n]{0,40}?(?:c[oó]digo|code|codice)"#, caseInsensitive: true)

    static func codes(_ text: String) -> [Detection] {
        var out: [Detection] = []
        for p in [codeAfter, codeBefore, codeUse, codeAlnum, cardSecurityCode, intlCodeAfter, intlCodeBefore] {
            for r in groups(p, text) { out.append(Detection(category: .codes, range: r)) }
        }
        return out
    }

    // MARK: Bank details

    private static let sortCodeContext = re(#"\b(?:sort\s*code|s/c)\b\s*(?:is|:|-|=)?\s*(\d{2}[ \-]?\d{2}[ \-]?\d{2})(?!\d)"#, caseInsensitive: true)
    /// A sort code followed by an 8-digit account number, even without labels: "20-00-00 12345678".
    private static let sortAndAccount = re(#"(?<![\d\-])(\d{2}-\d{2}-\d{2}[ ,/]+\d{8})(?!\d)"#)
    private static let accountContext = re(#"\b(?:account|acct|a/c|acc)\.?\s*(?:number|no\.?|num|#)?\s*(?:is|:|-|=)?\s*(\d[\d ]{4,18}\d)(?!\d)"#, caseInsensitive: true)
    private static let routingContext = re(#"\b(?:routing|aba|rtn)\s*(?:number|no\.?|num|#)?\s*(?:is|:|-|=)?\s*(\d{9})(?!\d)"#, caseInsensitive: true)
    /// Upper or lower case; the checksum decides.
    private static let ibanPattern = re(#"\b([A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30})\b"#, caseInsensitive: true)

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
    /// US SSN with one kind of separator (hyphen, space or dot), excluding impossible ranges.
    private static let ssnPattern = re(#"(?<![\d\-.])((?!000|666|9\d\d)\d{3}([\- .])(?!00)\d{2}\2(?!0000)\d{4})(?![\d\-]|\.\d)"#)
    private static let ssnContext = re(#"\b(?:ssn|social\s+security(?:\s+(?:number|no\.?))?)\s*(?:is|:|#|-)?\s*(\d{9}|\d{3}[\- .]\d{2}[\- .]\d{4})(?!\d)"#, caseInsensitive: true)
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

    private static let passwordWords = #"(?:\b(?:password|passwd|pwd|pw|passphrase|pass\s*word|wi-?fi\s*(?:password|pw|key|code)|contrase[nñ]a|senha|mot\s+de\s+passe|passwort|kennwort|pass(?=\s*:))\b|密码|密碼|パスワード)"#
    /// "for the wifi", "pour le wifi", "für das WLAN"… between the word and its value.
    private static let passwordFor = #"(?:\s+(?:for|to|of|on|de|du|para|pour|f[uü]r|per|da|di)\s+(?:the\s+|my\s+|your\s+|our\s+|la\s+|le\s+|el\s+|o\s+|a\s+|il\s+|das\s+|den\s+|die\s+|der\s+)?[\w'-]{1,20}){0,2}"#
    private static let passwordJoin = #"\s*(?:'s|’s|is|was|es|est|ist|lautet|é|è|是|为|為|は|:|=|-|–)\s*(?:now\s+)?"#
    /// A quoted value (spaces allowed inside) or one unquoted word (apostrophes allowed inside).
    private static let passwordValue = #"(?:"([^"\n]{1,100})"|“([^”\n]{1,100})”|‘([^’\n]{1,100})’|'([^'\n]{1,100})'|(?!["“‘'])([^\s"“”]{3,}))"#
    private static let passwordContext = re(passwordWords + passwordFor + passwordJoin + passwordValue, caseInsensitive: true)
    /// "password hunter22": no joining word, so the value must look like a password (a digit or symbol).
    private static let passwordBare = re(#"\b(?:password|passwd|pwd|pw|passphrase|contrase[nñ]a|senha|passwort|kennwort)\s+([^\s"“”]{4,})"#, caseInsensitive: true)
    /// "passcode is hunter22": a passcode with letters is a password (digits only are a code, above).
    private static let passcodeContext = re(#"\bpass\s*code"# + passwordFor + passwordJoin + passwordValue, caseInsensitive: true)
    private static let keyContext = re(#"\b(?:api[\s_-]?key|secret(?:[\s_-]?key)?|access[\s_-]?key|token|bearer|private[\s_-]?key|client[\s_-]?secret|recovery\s+(?:key|phrase)|seed\s+phrase)\s*(?:is|:|=|-)?\s*["'“‘]?([A-Za-z0-9_\-+/=.]{12,})"#, caseInsensitive: true)
    private static let knownKeys = re(#"(?<![A-Za-z0-9])((?:sk|pk|rk)[-_](?:live|test|proj|ant)?[-_]?[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|xox[abprs]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{35}|eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY(?: BLOCK)?-----|$))"#)
    /// A list of 12–24 words after "seed phrase", "recovery phrase"… (optionally numbered).
    private static let seedPhrase = re(#"\b(?:seed|recovery|mnemonic|backup|wallet)\s+(?:phrase|words)\b[^\n\w]{0,5}(?:(?:is|are)\b)?[\s:=\-–]*((?:(?:\d{1,2}[.)]\s*)?[a-z]{3,8}[\s,]+){11,23}(?:\d{1,2}[.)]\s*)?[a-z]{3,8})\b"#, caseInsensitive: true)
    /// The password in "scheme://user:password@host".
    private static let urlCredentials = re(#"\b[a-z][a-z0-9+.\-]{1,15}://[^\s/:@]{1,64}:([^\s/@]{1,128})@"#, caseInsensitive: true)
    /// Secret query values: "?token=…", "&sig=…", "pwd=…".
    private static let urlSecretParam = re(#"[?&#;](?:access_token|id_token|refresh_token|token|api_?key|apikey|key|secret|client_secret|sig|signature|password|passwd|pwd|pass|auth|code|session|sessionid|sid|otp|x-amz-signature|x-amz-credential)=([^&#\s]{4,})"#, caseInsensitive: true)
    /// Links that are themselves secrets.
    private static let secretURL = re(#"\bhttps?://(?:hooks\.slack\.com/services|discord(?:app)?\.com/api/webhooks|api\.telegram\.org/bot|[a-z0-9-]+\.webhook\.office\.com/webhookb2)/?(\S+)"#, caseInsensitive: true)
    private static let longToken = re(#"(?<![A-Za-z0-9_\-+/=])([A-Za-z0-9_\-+/=]{24,})(?![A-Za-z0-9_\-+/=])"#)
    /// A link: long ids in its path are page ids (share links, product pages), not secrets.
    private static let urlSpan = re(#"(?:\b[a-z][a-z0-9+.\-]{1,15}://|\bwww\.|(?<![a-z0-9.\-])(?:[a-z0-9-]{1,63}\.)++[a-z]{2,24}/)[^\s<>"'“”]*"#, caseInsensitive: true)

    static func secrets(_ text: String) -> [Detection] {
        var out: [Detection] = []
        func add(_ r: Range<String.Index>) { out.append(Detection(category: .secrets, range: r)) }
        for r in groups(passwordContext, text) { if let t = trimmed(r, text) { add(t) } }
        for r in groups(passwordBare, text) {
            // A digit anywhere, or a symbol before the end ("vergessen?" is a question, not a password).
            let body = text[r].dropLast()
            guard text[r].contains(where: \.isNumber) || body.contains(where: { "!@#$%^&*_+=~?<>|\\".contains($0) }) else { continue }
            if let t = trimmed(r, text) { add(t) }
        }
        for r in groups(passcodeContext, text) where text[r].contains(where: \.isLetter) { if let t = trimmed(r, text) { add(t) } }
        for p in [knownKeys, seedPhrase, urlCredentials, urlSecretParam, secretURL] {
            for r in groups(p, text) { add(r) }
        }
        // "token appreciation" isn't a key: labelled keys must contain a digit.
        for r in groups(keyContext, text) where text[r].contains(where: \.isNumber) { if let t = trimmed(r, text) { add(t) } }
        let links = matches(urlSpan, text)
        for r in groups(longToken, text) where looksRandom(text[r]) && !links.contains(where: { $0.overlaps(r) }) { add(r) }
        return out
    }

    /// Leaves sentence punctuation after a value visible: "pw: hunter22," masks "hunter22".
    private static func trimmed(_ r: Range<String.Index>, _ text: String) -> Range<String.Index>? {
        var end = r.upperBound
        while end > r.lowerBound, ".,;:)'’\"”".contains(text[text.index(before: end)]) { end = text.index(before: end) }
        return end > r.lowerBound ? r.lowerBound..<end : nil
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

    /// The first capture group that took part in each match.
    private static func groups(_ re: NSRegularExpression, _ text: String) -> [Range<String.Index>] {
        re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            for g in 1..<max(1, m.numberOfRanges) where m.range(at: g).location != NSNotFound {
                return Range(m.range(at: g), in: text)
            }
            return nil
        }
    }
}

/// The text the detectors scan, with a way back to the original. Each original character becomes
/// zero or more characters here: invisible formatting characters (bidi marks and isolates, zero-width
/// spaces, soft hyphens) are dropped, Unicode spaces become " ", line and paragraph separators "\n",
/// NFKC folds full-width and other compatibility forms, and Cyrillic/Greek look-alikes inside a word
/// that also has Latin letters become Latin. Matches map back to whole original characters.
struct Normalized {
    let text: String
    private let source: String
    /// For each UTF-16 unit of `text`, the UTF-16 range of the original character it came from. nil: identical.
    private let from: [(Int, Int)]?

    init(_ s: String) {
        source = s
        // Plain ASCII without control tricks needs nothing (the common case).
        if s.utf8.allSatisfy({ $0 < 0x80 }) { text = s; from = nil; return }
        var pieces: [(text: String, start: Int, end: Int)] = []
        var offset = 0
        for ch in s {
            let len = ch.utf16.count
            pieces.append((Self.piece(ch), offset, offset + len))
            offset += len
        }
        // Fold look-alikes only inside words that mix them with Latin letters ("pаssword"), never in Russian or Greek text.
        var i = 0
        while i < pieces.count {
            guard Self.isWordPiece(pieces[i].text) else { i += 1; continue }
            var j = i, latin = false, lookalike = false
            while j < pieces.count, Self.isWordPiece(pieces[j].text) || pieces[j].text.isEmpty {
                if pieces[j].text.unicodeScalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) { latin = true }
                if pieces[j].text.unicodeScalars.contains(where: { Self.lookalikes[$0] != nil }) { lookalike = true }
                j += 1
            }
            if latin && lookalike {
                for k in i..<j {
                    pieces[k].text = String(String.UnicodeScalarView(pieces[k].text.unicodeScalars.map { Self.lookalikes[$0] ?? $0 }))
                }
            }
            i = max(j, i + 1)
        }
        var out = "", map: [(Int, Int)] = []
        for p in pieces {
            out += p.text
            map.append(contentsOf: repeatElement((p.start, p.end), count: p.text.utf16.count))
        }
        text = out; from = map
    }

    /// The original characters behind a range of `text`.
    func original(_ r: Range<String.Index>) -> Range<String.Index>? {
        guard let from else { return r }
        let a = r.lowerBound.utf16Offset(in: text), b = r.upperBound.utf16Offset(in: text)
        guard a < b, b <= from.count else { return nil }
        let lo = String.Index(utf16Offset: from[a].0, in: source), hi = String.Index(utf16Offset: from[b - 1].1, in: source)
        return lo < hi ? lo..<hi : nil
    }

    private static func piece(_ ch: Character) -> String {
        // Full-width commas and stops stay as they are, so "845221，5分钟" isn't read as a decimal.
        if ch.isASCII || ch == "，" || ch == "．" { return String(ch) }
        var v = String.UnicodeScalarView()
        for u in ch.unicodeScalars {
            switch u.properties.generalCategory {
            case .format: continue
            case .spaceSeparator: v.append(" ")
            case .lineSeparator, .paragraphSeparator: v.append("\n")
            default: v.append(u)
            }
        }
        return String(v).precomposedStringWithCompatibilityMapping
    }

    private static func isWordPiece(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { $0.properties.isAlphabetic || $0.properties.generalCategory == .nonspacingMark }
    }

    /// Cyrillic and Greek letters that look like Latin ones.
    static let lookalikes: [Unicode.Scalar: Unicode.Scalar] = {
        let pairs: [(String, String)] = [
            ("аеорсухіјѕһԁԛԝӏ", "aeopcyxijshdqwl"),       // Cyrillic lower case
            ("АВЕКМНОРСТХУІЈЅ", "ABEKMHOPCTXYIJS"),       // Cyrillic upper case
            ("οορκινυ", "oopkivu"),                         // Greek lower case
            ("ΑΒΕΖΗΙΚΜΝΟΡΤΥΧ", "ABEZHIKMNOPTYX"),          // Greek upper case
        ]
        var m: [Unicode.Scalar: Unicode.Scalar] = [:]
        for (a, b) in pairs { for (x, y) in zip(a.unicodeScalars, b.unicodeScalars) { m[x] = y } }
        return m
    }()
}
