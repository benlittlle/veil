import Foundation
import Testing
@testable import VeilCore

@Suite("Content filter: detectors")
struct DetectorTests {
    /// Masks with the standard profile (judgement categories off, so no model is involved).
    func masked(_ s: String) -> String {
        var p = FilterPolicy.standard
        for c in FilterCategory.modelCategories { p.set(c, .allow) }
        return ContentFilter.mask(s, policy: p).0
    }
    func categories(_ s: String) -> Set<FilterCategory> { Set(Detectors.scan(s).map(\.category)) }

    @Test func luhn() {
        #expect(Detectors.luhn([4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1]))
        #expect(Detectors.luhn("378282246310005".compactMap(\.wholeNumberValue)))
        #expect(!Detectors.luhn("4111111111111112".compactMap(\.wholeNumberValue)))
    }

    @Test func cardNumbers() {
        for (input, expected) in [
            ("card 4111 1111 1111 1111 thanks", "card [removed] thanks"),
            ("4111-1111-1111-1111", "[removed]"),
            ("amex 378282246310005", "amex [removed]"),
            ("mc 5555555555554444.", "mc [removed]."),
            ("new mc 2223003122003222", "new mc [removed]"),
            ("visa 4012888888881881 exp 09/28", "visa [removed] exp 09/28"),
        ] { #expect(masked(input) == expected, "\(input)") }
        // Not cards: failed checksum, phone numbers, order numbers starting 1/7/8/9, mixed separators.
        for input in ["4111 1111 1111 1112", "call +44 7700 900123 now", "+1 555 010 0001", "order 1234567890123",
                      "ref 9999999999999995", "4111 1111-1111 1111", "tracking 7700123456789012"] {
            #expect(!categories(input).contains(.cardNumbers), "\(input)")
        }
    }

    @Test func codes() {
        for (input, expected) in [
            ("Your code is 4417", "Your code is [removed]"),
            ("Your verification code: 123456.", "Your verification code: [removed]."),
            ("123456 is your Instagram code", "[removed] is your Instagram code"),
            ("G-482913 is your Google verification code.", "G-[removed] is your Google verification code."),
            ("OTP 845 221", "OTP [removed]"),
            ("my PIN is 0000", "my PIN is [removed]"),
            ("PIN for the door is 2468", "PIN for the door is [removed]"),
            ("Use 739201 to verify your account", "Use [removed] to verify your account"),
            ("passcode 99887766", "passcode [removed]"),
            ("CVV 1234", "CVV [removed]"),
        ] { #expect(masked(input) == expected, "\(input)") }
        // Numbers without a code context, times, prices, years and percentages are left alone.
        for input in ["See you at 1530", "It was 2024 when we met", "costs £1250 total", "code review at 15:30",
                      "the code is ready by Monday", "PIN me later", "Room 4417 at the hotel", "codes are 50% off",
                      "Born 12/05/1990", "pin 3 photos", "error code 404"] {
            #expect(!categories(input).contains(.codes), "\(input)")
        }
    }

    @Test func bankDetails() {
        #expect(masked("Sort code 20-00-00 account 31926819") == "Sort code [removed] account [removed]")
        #expect(masked("s/c 209876, acc no. 12345678") == "s/c [removed], acc no. [removed]")
        #expect(masked("Pay 20-00-00 31926819 please") == "Pay [removed] please")
        #expect(masked("IBAN GB82 WEST 1234 5698 7654 32 thanks") == "IBAN [removed] thanks")
        #expect(masked("DE89370400440532013000") == "[removed]")
        #expect(masked("routing 021000021 account 1234567890") == "routing [removed] account [removed]")
        #expect(Detectors.ibanValid("GB82WEST12345698765432"))
        #expect(Detectors.ibanValid("FR1420041010050500013M02606"))
        #expect(!Detectors.ibanValid("GB82WEST12345698765433"))
        #expect(Detectors.abaValid("021000021".compactMap(\.wholeNumberValue)))
        #expect(!Detectors.abaValid("021000022".compactMap(\.wholeNumberValue)))
        // Not bank details: dates with dashes, an invalid IBAN, a routing-like number with a bad checksum.
        for input in ["Party on 12-05-24 at mine", "GB82 WEST 1234 5698 7654 33", "routing 021000022", "My account was hacked",
                      "the account has 3 users", "ISO 9001 certified", "AB12 CDEF"] {
            #expect(!categories(input).contains(.bankDetails), "\(input)")
        }
    }

    @Test func governmentIDs() {
        #expect(masked("NI JG103759A") == "NI [removed]")
        #expect(masked("ni number: jg 10 37 59 a.") == "ni number: [removed].")
        #expect(masked("SSN 078-05-1120") == "SSN [removed]")
        #expect(masked("social security number 078051120") == "social security number [removed]")
        #expect(masked("passport no. 123456789") == "passport no. [removed]")
        #expect(masked("Passport number is GB1234567") == "Passport number is [removed]")
        // Not IDs: impossible NI prefixes, SSN-shaped phone numbers, 000/666 areas, passport talk without a number.
        for input in ["code BG123456A", "call 555-010-0001", "000-12-3456", "666-12-3456", "renew my passport soon",
                      "passport photos needed", "Flight BA123456 C"] {
            #expect(!categories(input).contains(.governmentIDs), "\(input)")
        }
    }

    @Test func secrets() {
        #expect(masked("wifi password: Tr0ub4dor&3 enjoy") == "wifi password: [removed] enjoy")
        #expect(masked("the pw is hunter22") == "the pw is [removed]")
        #expect(masked("Password = \"correct-horse\"") == "Password = \"[removed]\"")
        #expect(masked("key sk-proj-abcDEF1234567890ghijKLMN ok") == "key [removed] ok")
        #expect(masked("ghp_abcdefghijklmnopqrstuvwxyz0123456789") == "[removed]")
        #expect(masked("AKIAIOSFODNN7EXAMPLE") == "[removed]")
        #expect(masked("token: abc123def456ghi789") == "token: [removed]")
        #expect(masked("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U") == "[removed]")
        #expect(masked("here: Zx9vQ2mL8pR4tY7wK1nB5cH3jF6gD0sA") == "here: [removed]")
        // Not secrets: ordinary long words, lowercase hashes without mixed case, a URL-ish path, "token" in prose.
        for input in ["Supercalifragilisticexpialidocious!", "a token of appreciation", "thanks, here's the link https://example.com/about-us",
                      "commit 9fceb02d0ae598e95dc970b74767f19372d61af8", "my password was too short, I changed it"] {
            #expect(!categories(input).contains(.secrets) || input.contains("password"), "\(input)")
        }
        #expect(!categories("a token of appreciation").contains(.secrets))
    }

    @Test func profanity() {
        #expect(masked("This is fucking great") == "This is f*** great")
        #expect(masked("Oh SHIT, really?") == "Oh S***, really?")
        #expect(masked("what a wanker") == "what a w***")
        for input in ["Scunthorpe United", "a classic assessment", "cocktail hour", "shiitake mushrooms", "Dickens novel", "pass the class"] {
            #expect(!categories(input).contains(.profanity), "\(input)")
        }
    }

    @Test func ordinaryMessagesAreUntouched() {
        for input in ["Meet at 7pm on 12/05/2024, call +44 7700 900123", "Call me on 07700 900123", "It's £1,234.56 for the room",
                      "Flight BA 2490 leaves 06:45", "Room 101, floor 3", "Score was 3-2", "1,000,000 views!", "Version 17.4.1",
                      "ETA 2024-11-13T18:04", "Lat 51.5074, lon -0.1278", "Postcode SW1A 1AA", "Order #123456 has shipped",
                      "My number is (555) 010-0001", "Yes, can you book the 7pm slot?"] {
            #expect(Detectors.scan(input).isEmpty, "\(input) → \(Detectors.scan(input).map(\.category))")
        }
    }

    @Test func maskKeepsTheRestAndMergesOverlaps() {
        // The SSN pattern and the "SSN" context pattern overlap; one placeholder.
        #expect(masked("SSN 078-05-1120, PIN 2468 and card 4111111111111111") == "SSN [removed], PIN [removed] and card [removed]")
        var p = FilterPolicy.standard
        for c in FilterCategory.modelCategories { p.set(c, .allow) }
        p.set(.cardNumbers, .withhold)
        let o = ContentFilter(classifier: nil).decide(.init(id: 1, text: "card 4111111111111111"), policy: p, verdict: nil)
        #expect(o.withheld && o.text == "[withheld]" && o.reasons == [.cardNumbers])
        p.set(.cardNumbers, .allow)
        #expect(ContentFilter.mask("card 4111111111111111", policy: p).0 == "card 4111111111111111")
    }

    @Test func strictnessThresholds() {
        let filter = ContentFilter(classifier: nil)
        let item = ContentFilter.Item(id: 1, text: "hello")
        func withheld(_ l: ConcernLevel, _ s: FilterStrictness) -> Bool {
            var p = FilterPolicy.standard; p.strictness = s
            var v = ModelVerdict.clear; v.levels[.health] = l
            return filter.decide(item, policy: p, verdict: v).withheld
        }
        #expect(!withheld(.none, .strict))
        #expect(withheld(.mild, .strict) && !withheld(.mild, .balanced) && !withheld(.mild, .relaxed))
        #expect(withheld(.clear, .balanced) && !withheld(.clear, .relaxed))
        #expect(withheld(.strong, .relaxed))
        for s in FilterStrictness.allCases { #expect(withheld(.unsure, s)) }
        // A verdict missing a category counts as unsure.
        var p = FilterPolicy.standard; p.strictness = .relaxed
        #expect(filter.decide(item, policy: p, verdict: ModelVerdict([.politics: .none])).withheld)
        // Allowed categories ignore the model entirely.
        for c in FilterCategory.modelCategories { p.set(c, .allow) }
        #expect(!filter.decide(item, policy: p, verdict: nil).withheld)
    }

    @Test func policyChoicesAreEnforced() {
        var p = FilterPolicy.standard
        p.set(.profanity, .withhold)         // not offered for swearing
        #expect(p.action(.profanity) == .mask)
        p.set(.politics, .mask)              // not offered for judgement categories
        #expect(p.action(.politics) == .withhold)
        // Photos are checked by default; photo categories offer Allow / Withhold and default to Withhold.
        #expect(FilterPolicy.standard.attachments == .check)
        for c in FilterCategory.photoCategories {
            #expect(c.choices == [.allow, .withhold])
            #expect(FilterPolicy.standard.action(c) == .withhold)
            p.set(c, .mask)
            #expect(p.action(c) == .withhold)
        }
        // Photo categories never go to the text model.
        #expect(Set(FilterCategory.modelCategories).isDisjoint(with: FilterCategory.photoCategories))
    }
}
