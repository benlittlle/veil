import Foundation
import Testing
@testable import VeilCore

// Red-team probes of the content filter: inputs that used to slip past the detectors, ordinary text that
// must stay visible, and every path that returns message content. Values are fake test data only.

/// Masks with the standard profile, judgement categories off (no model involved).
private func masked(_ s: String) -> String {
    var p = FilterPolicy.standard
    for c in FilterCategory.modelCategories { p.set(c, .allow) }
    return ContentFilter.mask(s, policy: p).0
}
private func categories(_ s: String) -> Set<FilterCategory> { Set(Detectors.scan(s).map(\.category)) }

/// CPU time this thread has used. Unlike the wall clock, it doesn't grow when the machine is busy.
private func threadCPUSeconds() -> Double {
    var t = timespec()
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t)
    return Double(t.tv_sec) + Double(t.tv_nsec) / 1e9
}

/// Appends the check digit that makes `partial` pass the card checksum.
private func luhnComplete(_ partial: String) -> String {
    let digits = partial.compactMap(\.wholeNumberValue)
    let d = (0...9).first { Detectors.luhn(digits + [$0]) }!
    return partial + String(d)
}

/// A probe input and the part of it that must not come out.
struct Probe: CustomTestStringConvertible, Sendable {
    let input: String
    let secret: String
    init(_ input: String, _ secret: String) { self.input = input; self.secret = secret }
    var testDescription: String { input.debugDescription }
}

// MARK: - Detectors: inputs that used to slip through

@Suite("RedactionProbe: formerly missed")
struct RedactionProbeDetectorGaps {
    static let groups = ["4111", "1111", "1111", "1111"]

    @Test(arguments: [".", "/", "\u{00A0}", "\u{202F}", "  ", " - ", "\n"])
    func cardWithOtherSeparators(_ sep: String) {
        let s = "card " + Self.groups.joined(separator: sep) + " thanks"
        #expect(masked(s) == "card [removed] thanks", "\(s.debugDescription)")
    }

    @Test(arguments: [luhnComplete("220000000000000"), luhnComplete("810000000000000"), luhnComplete("979200000000000")])
    func cardsOutsideTheTwoToSixPrefixes(_ number: String) {
        // Mir (2200–2204), RuPay (81/82) and Troy (9792) are real networks with Luhn-valid numbers.
        #expect(Detectors.luhn(number.compactMap(\.wholeNumberValue)))
        #expect(categories("card \(number)").contains(.cardNumbers), "\(number)")
    }

    @Test(arguments: ["cvv 123", "CVV: 123", "cvc is 456", "security code 789"])
    func threeDigitCardSecurityCodes(_ s: String) {
        #expect(categories(s).contains(.codes), "\(s)")
    }

    @Test(arguments: [Probe("Código: 845221", "845221"), Probe("Votre code est 845221", "845221"),
                      Probe("Ihr Code lautet 845221", "845221"), Probe("Dein Bestätigungscode: 845221", "845221"),
                      Probe("验证码：845221", "845221"), Probe("code：845221", "845221")])
    func oneTimeCodesInOtherLanguages(_ p: Probe) {
        #expect(!masked(p.input).contains(p.secret), "\(p.input)")
    }

    @Test(arguments: [Probe("Your code is G-845221", "845221"), Probe("Your code is A7K9Q2", "A7K9Q2"),
                      Probe("Your Steam Guard code: 7FKX2", "7FKX2"), Probe("PIN #2468", "2468"),
                      Probe("door code is #4417", "4417"), Probe("Enter 845221 on the sign-in page", "845221"),
                      Probe("845221 - your verification code", "845221"), Probe("code is 8 4 5 2 2 1", "8 4 5 2 2 1")])
    func oneTimeCodeShapes(_ p: Probe) {
        #expect(!masked(p.input).contains(p.secret), "\(p.input)")
    }

    @Test(arguments: [Probe("Your code is \u{2068}845221\u{2069}", "845221"), Probe("Your code is \u{200E}845221", "845221"),
                      Probe("code is 845\u{200B}221", "221"), Probe("card 4111\u{200B}1111\u{200B}1111\u{200B}1111", "1111"),
                      Probe("p\u{0430}ssword: hunter22", "hunter22")])
    func invisibleCharactersAndHomoglyphs(_ p: Probe) {
        #expect(!masked(p.input).contains(p.secret), "\(p.input.debugDescription)")
    }

    @Test(arguments: [Probe("the password for the wifi is hunter22", "hunter22"), Probe("password hunter22", "hunter22"),
                      Probe("my password's hunter22", "hunter22"), Probe("password is \"correct horse battery staple\"", "battery staple"),
                      Probe("password: Tr0ub4dor'3x", "'3x"), Probe("passcode is hunter22", "hunter22")])
    func passwordPhrasings(_ p: Probe) {
        #expect(!masked(p.input).contains(p.secret), "\(p.input)")
    }

    @Test func seedPhraseWords() {
        let s = "seed phrase: abandon ability able about above absent absorb abstract absurd abuse access accident"
        #expect(!masked(s).contains("absurd abuse"))
    }

    @Test(arguments: [Probe("postgres://admin:hunter2Pass@db.example.com:5432/app", "hunter2Pass"),
                      Probe("https://ben:S3cr3tPw@example.com/", "S3cr3tPw")])
    func credentialsInURLs(_ p: Probe) {
        #expect(!masked(p.input).contains(p.secret), "\(p.input)")
    }

    @Test(arguments: [Probe("iban gb82 west 1234 5698 7654 32", "5698 7654"), Probe("SSN 078.05.1120", "078.05.1120")])
    func lowercaseIBANAndDottedSSN(_ p: Probe) {
        #expect(!masked(p.input).contains(p.secret), "\(p.input)")
    }

    @Test func pgpPrivateKeyBlock() {
        let s = "-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBF0abcDEFghiJKLmnoPQRstuVWXyz0123456789abcdefGHIJKLMNOPqrstuv\nqR7sT2u\n=Ab1c\n-----END PGP PRIVATE KEY BLOCK-----"
        #expect(!masked(s).contains("qR7sT2u") && !masked(s).contains("=Ab1c"))
    }
}

// MARK: - Detectors: over-redaction and precision

@Suite("RedactionProbe: over-redaction")
struct RedactionProbeOverRedaction {
    @Test(arguments: ["zip code 90210", "area code 0161", "post code 2000", "promo code 2024", "error code 80070005", "dress code: 1920s"])
    func everydayCodesAreNotSecrets(_ s: String) {
        #expect(!categories(s).contains(.codes), "\(s) → \(masked(s))")
    }

    @Test(arguments: ["https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=abc",
                      "https://www.amazon.com/dp/B08N5WRWNW/ref=sr_1_3?crid=2M096C61O4MLT"])
    func shareLinksKeepTheirPath(_ s: String) {
        #expect(!categories(s).contains(.secrets), "\(s) → \(masked(s))")
    }

    @Test func luhnValidNumbersThatAreNotCards() {
        let imei = "IMEI " + luhnComplete("35693803564380")
        let d = luhnComplete("3021234567123456").map(String.init)
        let order = "Order " + d[0..<3].joined() + "-" + d[3..<10].joined() + "-" + d[10...].joined()
        #expect(!categories(imei).contains(.cardNumbers), "\(imei)")
        #expect(!categories(order).contains(.cardNumbers), "\(order)")
    }

    @Test func ordinaryIdentifiersAreLeftAlone() {
        for s in ["USPS 9400 1000 0000 0000 0000 00", "UPS 1Z999AA10123456784", "FedEx 7489 2345 6789", "VIN 1HGCM82633A004352",
                  "Meeting ID 845 2213 9087", "Call +1 (415) 555-2671", "Due 2024-11-13 at 09:30", "Total $1,234.56",
                  "Order #123456", "error code 404", "Gate B22, seat 14C", "Ticket 4417 at the deli counter"] {
            #expect(Detectors.scan(s).isEmpty, "\(s) → \(masked(s))")
        }
    }
}

@Suite("RedactionProbe: precision of the newer patterns")
struct RedactionProbePrecision {
    @Test func realCodesNextToTheExcludedKinds() {
        for (input, expected) in [
            ("door code 4417", "door code [removed]"), ("alarm code is 1234", "alarm code is [removed]"),
            ("the code is 4417", "the code is [removed]"), ("gift code 5512", "gift code [removed]"),
            ("Your Uber code: 8452", "Your Uber code: [removed]"), ("code: 845 221", "code: [removed]"),
        ] { #expect(masked(input) == expected, "\(input)") }
        for input in ["QR code 1234", "bar code 5012345678900", "country code 0044", "source code 2024", "postal code 10115",
                      "discount code 1234", "coupon code 5050", "status code 2001", "the dress code is smart", "colour code 4417"] {
            #expect(!categories(input).contains(.codes), "\(input) → \(masked(input))")
        }
    }

    @Test func otherLanguagesStayQuietOnOrdinaryText() {
        for input in ["código postal 28001", "Code postal 75001", "codice fiscale RSSMRA85T10A562S", "Postleitzahl 10115",
                      "El código está listo para revisar", "Der Code ist fertig", "Le code est prêt", "Il codice è pronto",
                      "電話番号は 03-1234-5678 です", "请拨打 0912 345 678", "Llámame al 612 345 678", "Ruf mich an: 0151 2345678",
                      "Le 12/05/2024 à 14h30", "Preis: 1.234,56 €", "Precio 1.250 €", "Am 13.11.2024 um 18:00",
                      "Passwort vergessen?", "Mot de passe oublié", "Olvidé mi contraseña otra vez"] {
            #expect(Detectors.scan(input).isEmpty, "\(input) → \(masked(input))")
        }
    }

    @Test func otherLanguagesMaskCodesAndPasswords() {
        for (input, expected) in [
            ("Tu código de verificación es: 845221", "Tu código de verificación es: [removed]"),
            ("Seu código é 845221", "Seu código é [removed]"),
            ("845221 es tu código de Instagram", "[removed] es tu código de Instagram"),
            ("Il tuo codice è 845221", "Il tuo codice è [removed]"),
            ("Ihr SMS-Code lautet: 845221", "Ihr SMS-Code lautet: [removed]"),
            ("您的验证码为：845221，5分钟内有效", "您的验证码为：[removed]，5分钟内有效"),
            ("認証コードは 845221 です", "認証コードは [removed] です"),
            ("验证码【845221】", "验证码【[removed]】"),
            ("Mi contraseña es hunter22", "Mi contraseña es [removed]"),
            ("Le mot de passe du wifi est hunter22", "Le mot de passe du wifi est [removed]"),
            ("Das Passwort ist hunter22", "Das Passwort ist [removed]"),
            ("密码是hunter22", "密码是[removed]"),
        ] { #expect(masked(input) == expected, "\(input) → \(masked(input))") }
    }

    @Test func cardSeparatorsStayQuietOnOtherNumbers() {
        for input in ["Call 0800.123.4567", "Server 192.168.100.200", "From 2024/11/13 to 2024/11/14", "pi is 3.14159265358979323846",
                      "07700 900123\n07700 900124", "Room 4417\nGate 1234", "Version 4.1.1.1111.1111", "Total 4,111.11",
                      "1.234.567.890.123 views", "Ref 4111 1111 1111 1111"] {
            #expect(!categories(input).contains(.cardNumbers), "\(input) → \(masked(input))")
        }
        // A trailing CVV or expiry doesn't stop the card itself being found.
        #expect(masked("4111 1111 1111 1111 123") == "[removed] 123")
        #expect(masked("4111 1111 1111 1111 12/27") == "[removed] 12/27")
    }

    @Test func passwordsWithoutAJoiningWordNeedToLookLikeOne() {
        for input in ["password reset needed", "use a password manager", "the password policy changed", "password 2fa on",
                      "my password was too long", "Password expired yesterday"] {
            #expect(!masked(input).contains("[removed]") || input.contains(" was "), "\(input) → \(masked(input))")
        }
        #expect(masked("pw: hunter22, thanks") == "pw: [removed], thanks")
        #expect(masked("The password is hunter22.") == "The password is [removed].")
        #expect(masked("password is \"correct horse battery staple\" ok") == "password is \"[removed]\" ok")
    }

    @Test func linksKeepTheirPathButNotTheirSecrets() {
        for input in ["https://www.youtube.com/watch?v=dQw4w9WgXcQ", "https://docs.example.com/document/d/1A2b3C4d5E6f7G8h9I0jKlMnOpQrStUvWxYz/edit",
                      "open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC"] {
            #expect(!categories(input).contains(.secrets), "\(input) → \(masked(input))")
        }
        #expect(masked("https://example.com/reset?token=Ab3dEf6hIj9kLm2nOp5qRs8t&lang=en") == "https://example.com/reset?token=[removed]&lang=en")
        #expect(masked("https://zoom.us/j/123456789?pwd=Xy12ab34Cd") == "https://zoom.us/j/123456789?pwd=[removed]")
        #expect(!masked("https://hooks.slack.com/services/T0000000/B0000000/XXXXXXXXXXXXXXXXXXXXXXXX").contains("T0000000"))
        // A long random string outside a link is still a secret.
        #expect(masked("here: Zx9vQ2mL8pR4tY7wK1nB5cH3jF6gD0sA") == "here: [removed]")
    }

    @Test func normalisationMapsBackToTheOriginalText() {
        // Invisible characters around the value stay where they were; the value itself is replaced.
        #expect(masked("Your code is \u{2068}845221\u{2069}") == "Your code is \u{2068}[removed]\u{2069}")
        #expect(masked("code is 845\u{200B}221 ok") == "code is [removed] ok")
        // Full-width and look-alike text is masked in the original characters, and the rest is untouched.
        #expect(masked("ｃｏｄｅ：８４５２２１ ok") == "ｃｏｄｅ：[removed] ok")
        #expect(masked("p\u{0430}ssword: hunter22 ok") == "p\u{0430}ssword: [removed] ok")
        // Look-alikes are folded only inside Latin words: Russian and Greek text is left as it is.
        #expect(Normalized("p\u{0430}ssword").text == "password")
        #expect(Normalized("Пароль сорок").text == "Пароль сорок")
        #expect(Normalized("ορος").text == "ορος")
        // Swearing keeps the original first letter.
        #expect(masked("what the f\u{200B}uck") == "what the f***")
    }

    @Test func numberedSeedPhrase() {
        let s = "Recovery phrase:\n1. abandon 2. ability 3. able 4. about 5. above 6. absent 7. absorb 8. abstract 9. absurd 10. abuse 11. access 12. accident"
        #expect(!masked(s).contains("absurd") && !masked(s).contains("accident"))
        #expect(!categories("my backup words are in the safe at home").contains(.secrets))
    }
}

// MARK: - Detectors: regressions

@Suite("RedactionProbe: detector regressions")
struct RedactionProbeDetectorRegressions {
    @Test func unusualButCoveredCardForms() {
        #expect(masked("４１１１ １１１１ １１１１ １１１１") == "[removed]")          // fullwidth digits
        #expect(masked("amex 3782 822463 10005") == "amex [removed]")               // 4-6-5 grouping
        #expect(masked("card 4111 1111 1111 1111👍") == "card [removed]👍")
        // A combining mark after the last digit doesn't crash, and no digit survives.
        let accented = masked("card 4111111111111111\u{0301} ok")
        #expect(!accented.contains("1111"))
    }

    @Test func knownSecretFormats() {
        for s in ["sk-ant-api03-abcdefghijklmnopqrstuv", "xoxb-1234567890-abcdefghij", "ghp_abcdefghijklmnopqrstuvwxyz0123456789",
                  "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----",
                  "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA"] {
            #expect(masked(s) == "[removed]", "\(s)")
        }
        #expect(masked("aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY") == "aws_secret_access_key = [removed]")
        #expect(masked("Recovery key: ABCD-1234-EFGH-5678-IJKL-9012-MNOP") == "Recovery key: [removed]")
        #expect(masked("Wi-Fi key: Tr0ub4dor&3") == "Wi-Fi key: [removed]")
        #expect(masked("pw:hunter22") == "pw:[removed]")
        #expect(masked("PASS: hunter22") == "PASS: [removed]")
    }

    @Test func codesAcrossLineBreaksAndNoBreakSpaces() {
        #expect(masked("verification code\n845221") == "verification code\n[removed]")
        #expect(masked("code:\u{00A0}845221") == "code:\u{00A0}[removed]")
        #expect(masked("Your one-time passcode is 845221") == "Your one-time passcode is [removed]")
        #expect(masked("otp=845221") == "otp=[removed]")
    }

    @Test func placeholderRevealsNothingAboutTheValue() {
        // Same marker whatever the length, network or last four digits.
        let a = masked("4111 1111 1111 1111"), b = masked("378282246310005"), c = masked(luhnComplete("401288888888188"))
        #expect(a == "[removed]" && b == a && c == a)
        #expect(masked("code is 1234") == masked("code is 12345678"))
        let o = ContentFilter(classifier: nil).decide(.init(id: 1, text: "pin 2468 and card 4111111111111111"),
                                                     policy: { var p = FilterPolicy.standard; for c in FilterCategory.modelCategories { p.set(c, .allow) }; return p }(),
                                                     verdict: nil)
        #expect(o.text == "pin [removed] and card [removed]")
        let shown = o.text ?? ""
        #expect(!shown.contains { $0.isNumber })
    }

    @Test func veryLongInputsFinishAndStillMask() {
        let cases: [(String, String)] = [
            (String(repeating: "4", count: 200_000), "digits"),
            (String(repeating: "code is 1234 ", count: 20_000), "codes"),
            (String(repeating: "Ab3dEf6hIj9kLm2n", count: 10_000), "token"),
            (String(repeating: "GB82 ", count: 40_000), "iban-ish"),
            (String(repeating: "🙂4111 1111 1111 1111 ", count: 10_000), "cards+emoji"),
            (String(repeating: "password: ", count: 20_000), "keywords"),
        ]
        for (s, what) in cases {
            let start = threadCPUSeconds()
            let out = masked(s)
            #expect(threadCPUSeconds() - start < 30, "\(what) took too long")
            if what == "codes" { #expect(!out.contains("1234")) }
            if what == "cards+emoji" { #expect(!out.contains("4111")) }
            if what == "token" { #expect(out == "[removed]") }
        }
    }
}

// MARK: - Every path that returns content

/// Alex filtered, with photos & files on.
private let alexWithPhotos = Harness.defaultAccess.merging([
    ID.alex: ChatAccess(read: true, waiting: true, draft: true, attachments: true, filtered: true),
]) { $1 }

extension FilterHarness {
    /// A message whose text lives only in attributedBody, as on newer macOS.
    @discardableResult
    func addBodyOnly(_ name: String, _ body: String, hoursAgo: Double) throws -> Int64 {
        let (id, _) = try add(name, "", hoursAgo: hoursAgo)
        try db.query("UPDATE message SET text = NULL, attributedBody = ? WHERE ROWID = ?", [.blob(DemoData.archived(body)), .int(id)])
        return id
    }

    /// An attachment on a new Alex message, pointing at the fixture's garden photo, with the given file name.
    func addAttachment(id: Int64, name: String, messageText: String) throws {
        let (mid, _) = try add("att\(id)", messageText, hoursAgo: 0.3)
        let garden = h.dir.appendingPathComponent("Attachments/ab/01/ATT-1/garden.png")
        try db.query("INSERT INTO attachment VALUES (?, ?, ?, ?, ?, ?)",
                     [.int(id), .text("ATT-\(id)"), .text(garden.path), .text("image/png"), .text(name), .int(100)])
        try db.query("INSERT INTO message_attachment_join VALUES (?, ?)", [.int(mid), .int(id)])
        try db.query("UPDATE message SET cache_has_attachments = 1 WHERE ROWID = ?", [.int(mid)])
    }
}

@Suite("RedactionProbe: surfaces")
struct RedactionProbeSurfaces {
    @Test func attributedBodyOnlyMessagesAreFilteredEverywhere() throws {
        let f = try FilterHarness()
        try f.addBodyOnly("body", "Card 5555 5555 5555 4444, PIN 9753", hoursAgo: 0.2)
        #expect(f.text(of: "body") == "Card [removed], PIN [removed]")
        for q in ["5555", "4444", "9753", "PIN 9"] {
            let out = f.call("search_messages", ["query": .string(q), "limit": 50])
            #expect(out.json["results"]?.array?.isEmpty == true, "search for \(q) found something")
        }
        let visible = f.call("search_messages", ["query": "Card", "chat_id": .string(ID.alex), "limit": 50])
        let texts = visible.json["results"]?.array?.compactMap { $0["message"]?["text"]?.string } ?? []
        #expect(texts.contains("Card [removed], PIN [removed]"))
        #expect(!visible.raw.contains("5555") && !visible.raw.contains("9753"))
        let waiting = f.call("waiting_on_reply", ["days": 90])
        let alex = waiting.json["waiting"]?.array?.first { $0["chat_id"]?.string == ID.alex }
        #expect(alex?["last_message"]?.string == "Card [removed], PIN [removed]")
    }

    @Test func attachmentPlaceholderInsideACardNumber() throws {
        // Messages puts U+FFFC where an inline attachment sits; it's stripped before the filter runs.
        let f = try FilterHarness()
        try f.add("fffc", "card 5555 5555\u{FFFC} 5555 4444", hoursAgo: 0.2)
        #expect(f.text(of: "fffc") == "card [removed]")
    }

    @Test func truncatedPreviewsAreMaskedBeforeTheyAreCut() throws {
        let f = try FilterHarness()
        let (_, quoted) = try f.add("long-quoted", String(repeating: "q", count: 195) + " pw: hunter22abc", hoursAgo: 0.4)
        try f.add("reply-long", "noted", hoursAgo: 0.3, replyTo: quoted)
        try f.add("long-last", String(repeating: "x", count: 268) + " card 4111 1111 1111 1111 end", hoursAgo: 0.1)
        let waiting = f.call("waiting_on_reply", ["days": 90])
        let last = waiting.json["waiting"]?.array?.first { $0["chat_id"]?.string == ID.alex }?["last_message"]?.string ?? ""
        #expect(last.count == 280)
        #expect(!last.contains("4111") && !last.contains("1111"))
        let reply = f.messages().first { $0["id"]?.int.map(Int64.init) == f.ids["reply-long"] }
        let quote = reply?["reply_to"]?["text"]?.string ?? ""
        #expect(!quote.isEmpty && !quote.contains("hunter22"))
    }

    @Test func allowingAReplyDoesNotUnmaskItsQuote() throws {
        let f = try FilterHarness()
        let (_, guid) = try f.add("safe", "PIN for the safe is 9753", hoursAgo: 0.4)
        let (reply, _) = try f.add("ack", "ok noted, pin 1357 for mine", hoursAgo: 0.3, replyTo: guid)
        try f.gate.setFilterAllowed(true, message: reply, in: ID.alex)
        let m = try #require(f.messages().first { $0["id"]?.int.map(Int64.init) == reply })
        #expect(m["text"]?.string == "ok noted, pin 1357 for mine")           // the user let this one through
        #expect(m["reply_to"]?["text"]?.string == "PIN for the safe is [removed]")
        #expect(f.call("search_messages", ["query": "9753"]).json["results"]?.array?.isEmpty == true)
    }

    @Test func attachmentNamesAreMaskedOnEveryPath() throws {
        let f = try FilterHarness(access: alexWithPhotos)
        var p = FilterPolicy.standard
        p.attachments = .allow
        try f.gate.setChatFilterPolicy(p, for: ID.alex)
        try f.addAttachment(id: 50, name: "card 4111111111111111 receipt.png", messageText: "see attached")

        let read = f.call("read_chat", ["chat_id": .string(ID.alex), "limit": 200])
        #expect(read.raw.contains("card [removed] receipt.png"))
        let list = f.call("list_attachments", ["chat_id": .string(ID.alex)])
        #expect(list.raw.contains("card [removed] receipt.png"))
        let get = f.call("get_attachment", ["attachment_id": 50])
        #expect(!get.isError)
        #expect(get.text.contains("card [removed] receipt.png"))
        for (what, s) in [("read_chat", read.raw), ("list_attachments", list.raw), ("get_attachment", get.text)] {
            #expect(!s.contains("4111"), "\(what) leaked the card in a file name")
        }

        // Set to Withhold: the message carrying the name is withheld, and the attachment goes with it.
        p.set(.cardNumbers, .withhold)
        try f.gate.setChatFilterPolicy(p, for: ID.alex)
        let read2 = f.call("read_chat", ["chat_id": .string(ID.alex), "limit": 200])
        #expect(f.text(of: "att50") == "[withheld]")
        #expect(!read2.raw.contains("receipt"))
        #expect(f.call("list_attachments", ["chat_id": .string(ID.alex)]).json["attachments"]?.array?.contains { $0["attachment_id"]?.int == 50 } == false)
        #expect(f.call("get_attachment", ["attachment_id": 50]).isError)
    }

    @Test func attachmentNamesFailClosedWithoutTheModel() throws {
        let f = try FilterHarness(access: alexWithPhotos)
        var p = FilterPolicy.standard
        p.attachments = .allow
        try f.gate.setChatFilterPolicy(p, for: ID.alex)
        try f.addAttachment(id: 51, name: "biopsy results.png", messageText: "here")
        f.fake.behavior = .unavailable
        let list = f.call("list_attachments", ["chat_id": .string(ID.alex)])
        #expect(!list.raw.contains("biopsy"))
        #expect(!f.call("read_chat", ["chat_id": .string(ID.alex), "limit": 200]).raw.contains("biopsy"))
        #expect(f.call("get_attachment", ["attachment_id": 51]).isError)
    }

    @Test func filteredGroupChatNameIsNotFiltered() throws {
        let access = Harness.defaultAccess.merging([
            ID.alex: ChatAccess(read: true, waiting: true, draft: true, filtered: true),
            ID.climbing: ChatAccess(read: true, waiting: true, filtered: true),
        ]) { $1 }
        let f = try FilterHarness(access: access)
        try f.db.query("UPDATE chat SET display_name = 'Gate code is 7391' WHERE ROWID = 6")
        let list = f.call("list_chats")
        let read = f.call("read_chat", ["chat_id": .string(ID.climbing)])
        #expect(!list.raw.contains("7391"))
        #expect(!read.raw.contains("7391"))
    }
}

@Suite("RedactionProbe: names across chats")
struct RedactionProbeNames {
    @Test func listChatsQueryCantFindAMaskedName() throws {
        let access = Harness.defaultAccess.merging([ID.climbing: ChatAccess(read: true, waiting: true, filtered: true)]) { $1 }
        let f = try FilterHarness(access: access)
        try f.db.query("UPDATE chat SET display_name = 'Gate code is 7391' WHERE ROWID = 6")
        #expect(f.call("list_chats", ["query": "7391"]).json["chats"]?.array?.isEmpty == true)
        #expect(f.call("list_chats", ["query": "gate code"]).json["chats"]?.array?.first?["name"]?.string == "Gate code is [removed]")
        // Search results, waiting_on_reply and refusals use the masked name too.
        let out = [f.call("search_messages", ["query": "Thursday"]).raw, f.call("waiting_on_reply", ["days": 90]).raw,
                   f.call("list_attachments", ["chat_id": .string(ID.climbing)]).raw, f.call("chat_activity", ["chat_id": .string(ID.climbing)]).raw]
        for o in out { #expect(!o.contains("7391")) }
        // An unfiltered chat's name is shown as it is.
        try f.gate.setFiltered(false, for: ID.climbing)
        #expect(f.call("list_chats").raw.contains("Gate code is 7391"))
    }

    @Test func attachmentNameSharedWithAFilteredChat() throws {
        // Mom is unfiltered with photos; Alex is filtered with photos allowed. One attachment row is on a message in each.
        let f = try FilterHarness(access: alexWithPhotos)
        var p = FilterPolicy.standard
        p.attachments = .allow
        try f.gate.setChatFilterPolicy(p, for: ID.alex)
        try f.addAttachment(id: 60, name: "pw: hunter22 notes.png", messageText: "for you")
        let (momMsg, _) = try f.add("mom-copy", "forwarding this", hoursAgo: 0.25, chatRow: 1)
        try f.db.query("INSERT INTO message_attachment_join VALUES (?, 60)", [.int(momMsg)])
        try f.db.query("UPDATE message SET cache_has_attachments = 1 WHERE ROWID = ?", [.int(momMsg)])
        let read = f.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200])
        let list = f.call("list_attachments", ["chat_id": .string(ID.mom)])
        let get = f.call("get_attachment", ["attachment_id": 60])
        for (what, o) in [("read_chat", read.raw), ("list_attachments", list.raw), ("get_attachment", get.text)] {
            #expect(!o.contains("hunter22"), "\(what)")
        }
        #expect(read.raw.contains("pw: [removed] notes.png") && list.raw.contains("pw: [removed] notes.png"))
        // Where the filtered chat withholds passwords, the attachment isn't shown from the other chat either.
        p.set(.secrets, .withhold)
        try f.gate.setChatFilterPolicy(p, for: ID.alex)
        let read2 = f.call("read_chat", ["chat_id": .string(ID.mom), "limit": 200])
        #expect(!read2.raw.contains("notes.png"))
        #expect(f.call("list_attachments", ["chat_id": .string(ID.mom)]).json["attachments"]?.array?.contains { $0["attachment_id"]?.int == 60 } == false)
        #expect(f.call("get_attachment", ["attachment_id": 60]).isError)
    }
}

// MARK: - Fail closed

/// Answers with whatever `answer` returns. Always says it's available and on-device.
private final class ScriptedClassifier: ContentClassifier, @unchecked Sendable {
    let engineID = "scripted/1"
    let isOnDevice = true
    var status: ClassifierStatus { .available }
    let answer: @Sendable ([ClassifierItem]) -> [Int64: ModelVerdict]
    init(_ answer: @escaping @Sendable ([ClassifierItem]) -> [Int64: ModelVerdict]) { self.answer = answer }
    func classify(_ items: [ClassifierItem], completion: @escaping @Sendable (Result<[Int64: ModelVerdict], Error>) -> Void) {
        completion(.success(answer(items)))
    }
}

@Suite("RedactionProbe: fails closed")
struct RedactionProbeFailClosed {
    @Test func answersForIDsThatWerentAskedAreIgnored() {
        // Every batch answers "clear" for the first batch's ids, never for its own.
        let c = ScriptedClassifier { _ in Dictionary(uniqueKeysWithValues: (1...8).map { (Int64($0), ModelVerdict.clear) }) }
        let filter = ContentFilter(classifier: c)
        let items = (101...112).map { ContentFilter.Item(id: Int64($0), text: "message \($0)") }
        let out = filter.evaluate(items, policy: .standard, timeout: 2)
        for id in 101...108 { #expect(out[Int64(id)]?.withheld == false, "\(id)") }
        for id in 109...112 {
            #expect(out[Int64(id)]?.withheld == true, "\(id) was cleared by someone else's answer")
            #expect(out[Int64(id)]?.text == FilterOutcome.withheldMarker)
        }
    }

    @Test func aLongMessageWithAnUnansweredPieceIsWithheld() {
        // The model answers every piece except the one holding the end of the message.
        let c = ScriptedClassifier { items in
            Dictionary(uniqueKeysWithValues: items.filter { !$0.text.contains("TAILMARK") }.map { ($0.id, ModelVerdict.clear) })
        }
        let filter = ContentFilter(classifier: c)
        let long = String(repeating: "Plenty of ordinary words here. ", count: 60) + "TAILMARK the scan results came back"
        #expect(ContentFilter.chunksForModel(long).count >= 2)
        let out = filter.evaluate([.init(id: 1, text: long), .init(id: 2, text: "see you at 7")], policy: .standard, timeout: 2)
        #expect(out[1]?.withheld == true && out[1]?.notCleared == true)
        #expect(out[1]?.text == FilterOutcome.withheldMarker)
        #expect(out[2]?.withheld == false)
        #expect(filter.cachedCount == 1, "a partly judged message was cached")
    }

    @Test(.enabled(if: !AppleOnDeviceClassifier().status.isAvailable, "Apple Intelligence is available here, so the unavailable path can't be exercised"))
    func appleModelUnavailableWithholds() {
        let filter = ContentFilter(classifier: AppleOnDeviceClassifier())
        #expect(!filter.modelStatus.isAvailable)
        let out = filter.evaluate([.init(id: 1, text: "see you at 7", attachments: [(id: 9, name: "plan.png")])], policy: .standard, timeout: 1)
        #expect(out[1]?.withheld == true && out[1]?.notCleared == true)
        #expect(out[1]?.attachmentNames.isEmpty == true)
    }

    @Test func detectorsStillMaskWhenTheModelIsDownAndTopicsAreAllowed() {
        // Judgement categories on Allow: no model needed, but pattern categories still apply in full.
        var p = FilterPolicy.standard
        for c in FilterCategory.modelCategories { p.set(c, .allow) }
        let filter = ContentFilter(classifier: ScriptedClassifier { _ in [:] })
        let out = filter.evaluate([.init(id: 1, text: "pw: hunter22 and card 4111 1111 1111 1111",
                                         attachments: [(id: 3, name: "PIN 2468.png")])], policy: p, timeout: 1)
        #expect(out[1]?.withheld == false)
        #expect(out[1]?.text == "pw: [removed] and card [removed]")
        #expect(out[1]?.attachmentNames[3] == "PIN [removed].png")
    }
}
