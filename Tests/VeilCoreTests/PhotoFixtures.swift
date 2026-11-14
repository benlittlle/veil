import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import VeilCore

/// Synthetic pictures drawn with CoreGraphics, for the photo-check tests and the opt-in eval.
/// Everything here is made up: test card numbers, invented names, fake documents. No real data,
/// and nothing explicit.
enum PhotoFixtures {
    struct Sample {
        let name: String
        /// Categories a correct check would withhold it for (empty = should be shared).
        let expect: Set<FilterCategory>
        let image: CGImage
    }

    // MARK: Drawing helpers

    final class Canvas {
        let ctx: CGContext
        let w: CGFloat, h: CGFloat
        init(_ w: Int, _ h: Int, bg: (CGFloat, CGFloat, CGFloat) = (1, 1, 1)) {
            ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            self.w = CGFloat(w); self.h = CGFloat(h)
            fill(CGRect(x: 0, y: 0, width: w, height: h), bg)
        }
        /// y is measured from the top, like a page.
        func text(_ s: String, x: CGFloat, y: CGFloat, size: CGFloat, color: (CGFloat, CGFloat, CGFloat) = (0.1, 0.1, 0.1),
                  bold: Bool = false, mono: Bool = false) {
            let name = mono ? "Menlo-Regular" : (bold ? "Helvetica-Bold" : "Helvetica")
            let font = CTFontCreateWithName(name as CFString, size, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            ctx.textPosition = CGPoint(x: x, y: h - y - size)
            CTLineDraw(line, ctx)
        }
        func fill(_ r: CGRect, _ c: (CGFloat, CGFloat, CGFloat), radius: CGFloat = 0, top: Bool = true) {
            let rr = top ? CGRect(x: r.minX, y: h - r.minY - r.height, width: r.width, height: r.height) : r
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.addPath(CGPath(roundedRect: rr, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.fillPath()
        }
        func oval(_ r: CGRect, _ c: (CGFloat, CGFloat, CGFloat)) {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fillEllipse(in: CGRect(x: r.minX, y: h - r.minY - r.height, width: r.width, height: r.height))
        }
        func gradient(_ a: (CGFloat, CGFloat, CGFloat), _ b: (CGFloat, CGFloat, CGFloat)) {
            let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                               colors: [CGColor(red: a.0, green: a.1, blue: a.2, alpha: 1), CGColor(red: b.0, green: b.1, blue: b.2, alpha: 1)] as CFArray,
                               locations: [0, 1])!
            ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: w, y: h), options: [])
        }
        var image: CGImage { ctx.makeImage()! }
    }

    /// Puts a picture on a "table", slightly rotated, like a phone photo of it.
    static func onTable(_ img: CGImage, angle: CGFloat = -0.06) -> CGImage {
        let c = Canvas(img.width + 300, img.height + 300)
        c.gradient((0.55, 0.42, 0.30), (0.40, 0.30, 0.22))
        c.ctx.translateBy(x: c.w / 2, y: c.h / 2)
        c.ctx.rotate(by: angle)
        c.ctx.draw(img, in: CGRect(x: -CGFloat(img.width) / 2, y: -CGFloat(img.height) / 2, width: CGFloat(img.width), height: CGFloat(img.height)))
        return c.image
    }

    static func card(number: String?, color: (CGFloat, CGFloat, CGFloat), brand: String, back: Bool = false) -> CGImage {
        let c = Canvas(856, 540, bg: (1, 1, 1))
        c.fill(CGRect(x: 0, y: 0, width: 856, height: 540), color, radius: 36)
        if back {
            c.fill(CGRect(x: 0, y: 60, width: 856, height: 100), (0.05, 0.05, 0.05))
            c.fill(CGRect(x: 60, y: 210, width: 520, height: 70), (0.95, 0.95, 0.9))
            c.text("AUTHORISED SIGNATURE", x: 66, y: 290, size: 18, color: (0.9, 0.9, 0.9))
            c.text("123", x: 610, y: 225, size: 36, color: (0.9, 0.9, 0.9), mono: true)
            c.text("\(brand) · customer services 0345 000 0000", x: 60, y: 440, size: 24, color: (0.9, 0.9, 0.9))
            return c.image
        }
        c.text(brand, x: 60, y: 50, size: 44, color: (1, 1, 1), bold: true)
        c.fill(CGRect(x: 70, y: 170, width: 110, height: 85), (0.85, 0.72, 0.35), radius: 12)   // chip
        if let number { c.text(number, x: 60, y: 300, size: 58, color: (1, 1, 1), mono: true) }
        c.text("VALID THRU 12/29", x: 60, y: 400, size: 26, color: (0.95, 0.95, 0.95))
        c.text("MR J SAMPLE", x: 60, y: 450, size: 30, color: (1, 1, 1))
        c.oval(CGRect(x: 690, y: 420, width: 70, height: 70), (0.9, 0.2, 0.2))
        c.oval(CGRect(x: 735, y: 420, width: 70, height: 70), (0.95, 0.65, 0.1))
        return c.image
    }

    static func idCard(title: String, lines: [String], color: (CGFloat, CGFloat, CGFloat), mrz: [String] = []) -> CGImage {
        let c = Canvas(1000, 640, bg: (1, 1, 1))
        c.fill(CGRect(x: 0, y: 0, width: 1000, height: 640), color, radius: 30)
        c.text(title, x: 40, y: 30, size: 40, color: (0.1, 0.2, 0.4), bold: true)
        c.fill(CGRect(x: 40, y: 110, width: 250, height: 320), (0.75, 0.78, 0.8), radius: 8)     // photo box
        c.oval(CGRect(x: 105, y: 150, width: 120, height: 140), (0.55, 0.45, 0.4))              // head
        c.fill(CGRect(x: 75, y: 300, width: 180, height: 130), (0.3, 0.35, 0.5), radius: 60)    // shoulders
        for (i, l) in lines.enumerated() { c.text(l, x: 320, y: 120 + CGFloat(i) * 46, size: 30) }
        for (i, l) in mrz.enumerated() { c.text(l, x: 30, y: 520 + CGFloat(i) * 44, size: 28, mono: true) }
        return c.image
    }

    static func page(_ lines: [String], header: String? = nil, size: CGFloat = 26) -> CGImage {
        let c = Canvas(1240, 1754, bg: (0.98, 0.98, 0.96))
        var y: CGFloat = 90
        if let header { c.text(header, x: 90, y: y, size: 44, color: (0.1, 0.25, 0.5), bold: true); y += 110 }
        for l in lines { c.text(l, x: 90, y: y, size: size); y += size * 1.8 }
        return c.image
    }

    /// A phone screenshot of a chat. `(text, fromMe)` per bubble.
    static func chatScreenshot(_ bubbles: [(String, Bool)], title: String) -> CGImage {
        let c = Canvas(780, 1688, bg: (1, 1, 1))
        c.text("9:41", x: 60, y: 30, size: 30, bold: true)
        c.fill(CGRect(x: 0, y: 90, width: 780, height: 150), (0.96, 0.96, 0.97))
        c.oval(CGRect(x: 350, y: 100, width: 80, height: 80), (0.6, 0.6, 0.65))
        c.text(title, x: 390 - CGFloat(title.count) * 9, y: 190, size: 30)
        var y: CGFloat = 300
        for (t, me) in bubbles {
            let width = min(CGFloat(t.count) * 17 + 60, 600)
            let x: CGFloat = me ? 780 - width - 30 : 30
            let lines = wrap(t, 32)
            let h = CGFloat(lines.count) * 44 + 30
            c.fill(CGRect(x: x, y: y, width: width, height: h), me ? (0.0, 0.48, 1.0) : (0.9, 0.9, 0.92), radius: 34)
            for (i, l) in lines.enumerated() { c.text(l, x: x + 28, y: y + 14 + CGFloat(i) * 44, size: 30, color: me ? (1, 1, 1) : (0.05, 0.05, 0.05)) }
            y += h + 30
        }
        return c.image
    }

    static func wrap(_ s: String, _ n: Int) -> [String] {
        var lines: [String] = [], cur = ""
        for w in s.split(separator: " ") {
            if cur.count + w.count + 1 > n, !cur.isEmpty { lines.append(cur); cur = "" }
            cur += (cur.isEmpty ? "" : " ") + w
        }
        if !cur.isEmpty { lines.append(cur) }
        return lines
    }

    static func meme(top: String, bottom: String, bg: (CGFloat, CGFloat, CGFloat), face: Bool = true) -> CGImage {
        let c = Canvas(1000, 1000, bg: bg)
        c.gradient(bg, (bg.0 * 0.6, bg.1 * 0.6, bg.2 * 0.6))
        if face {
            c.oval(CGRect(x: 300, y: 300, width: 400, height: 400), (0.98, 0.82, 0.25))
            c.oval(CGRect(x: 400, y: 420, width: 50, height: 70), (0.1, 0.1, 0.1))
            c.oval(CGRect(x: 550, y: 420, width: 50, height: 70), (0.1, 0.1, 0.1))
            c.fill(CGRect(x: 420, y: 580, width: 160, height: 30), (0.1, 0.1, 0.1), radius: 15)
        }
        c.text(top, x: 500 - CGFloat(top.count) * 19, y: 60, size: 64, color: (1, 1, 1), bold: true)
        c.text(bottom, x: 500 - CGFloat(bottom.count) * 19, y: 860, size: 64, color: (1, 1, 1), bold: true)
        return c.image
    }

    static func note(_ lines: [String], color: (CGFloat, CGFloat, CGFloat) = (1, 0.93, 0.45)) -> CGImage {
        let c = Canvas(900, 900, bg: color)
        for (i, l) in lines.enumerated() { c.text(l, x: 70, y: 120 + CGFloat(i) * 90, size: 54) }
        return onTable(c.image, angle: 0.04)
    }

    // MARK: The sets

    static var sensitive: [Sample] {[
        Sample(name: "visa card", expect: [.paymentCards, .cardNumbers],
               image: card(number: "4242 4242 4242 4242", color: (0.1, 0.25, 0.6), brand: "DEMO BANK")),
        Sample(name: "mastercard on table", expect: [.paymentCards, .cardNumbers],
               image: onTable(card(number: "5555 5555 5555 4444", color: (0.12, 0.12, 0.14), brand: "SAMPLE CREDIT"))),
        Sample(name: "card back", expect: [.paymentCards],
               image: onTable(card(number: nil, color: (0.2, 0.45, 0.35), brand: "DEMO BANK", back: true), angle: 0.05)),
        Sample(name: "card without full number", expect: [.paymentCards],
               image: card(number: "•••• •••• •••• 4242", color: (0.55, 0.1, 0.2), brand: "TEST DEBIT")),
        Sample(name: "driving licence", expect: [.idDocuments],
               image: idCard(title: "DRIVING LICENCE", lines: ["1. SAMPLE", "2. JOHN PETER", "3. 01.02.1985 UNITED KINGDOM",
                                                               "4a. 12.03.2020  4b. 11.03.2030", "5. SAMPL851015JP9AB", "8. 1 TEST ROAD, LONDON"],
                             color: (0.85, 0.9, 0.95))),
        Sample(name: "passport", expect: [.idDocuments],
               image: onTable(idCard(title: "PASSPORT", lines: ["Surname: SAMPLE", "Given names: JOHN", "Nationality: BRITISH CITIZEN",
                                                                 "Date of birth: 01 JAN 85", "Date of expiry: 01 JAN 30"],
                                     color: (0.93, 0.9, 0.85),
                                     mrz: ["P<GBRSAMPLE<<JOHN<<<<<<<<<<<<<<<<<<<<<<<<<<", "1234567897GBR8501017M3001012<<<<<<<<<<<<<<02"]))),
        Sample(name: "national id card", expect: [.idDocuments],
               image: idCard(title: "NATIONAL IDENTITY CARD", lines: ["Name: MARIA EXAMPLE", "Born: 14.07.1990", "Card no: TX9184723",
                                                                     "Expires: 2031"], color: (0.92, 0.88, 0.95))),
        Sample(name: "bank letter with account number", expect: [.personalDocuments, .bankDetails],
               image: page(["Mr J Sample", "1 Test Road", "London AB1 2CD", "", "Dear Mr Sample,",
                            "Your new current account is ready to use.", "Sort code: 20-00-00",
                            "Account number: 31926819", "Your opening balance is £1,204.33.", "",
                            "Yours sincerely,", "Customer Services"], header: "Demo Bank plc")),
        Sample(name: "bank statement", expect: [.personalDocuments],
               image: page(["Statement for Mr J Sample, 1 Test Road, London", "Period 1 Oct to 31 Oct",
                            "Date      Description              Out        In        Balance",
                            "01 Oct    Opening balance                                 £812.40",
                            "03 Oct    SAMPLE SUPERMARKET        £54.20                £758.20",
                            "05 Oct    SALARY EXAMPLE LTD                  £2,140.00   £2,898.20",
                            "09 Oct    RENT                      £950.00               £1,948.20",
                            "31 Oct    Closing balance                                 £1,603.77"], header: "Demo Bank statement", size: 22)),
        Sample(name: "electricity bill", expect: [.personalDocuments],
               image: page(["Mr J Sample", "1 Test Road, London AB1 2CD", "", "Your electricity bill",
                            "Customer reference: 993812-04", "Billing period: 1 Sep - 30 Sep",
                            "Amount due: £143.20 by 21 October", "Direct debit will be taken on 21 October."], header: "Example Energy")),
        Sample(name: "medical results letter", expect: [.personalDocuments, .health],
               image: page(["Patient: John Sample   DOB 01/01/1985", "", "Dear Mr Sample,",
                            "Your blood test results show raised cholesterol and low iron.",
                            "Please book an appointment with your GP to discuss treatment.",
                            "Prescription: atorvastatin 20mg once daily."], header: "Example Health Clinic")),
        Sample(name: "screenshot with code", expect: [.codes, .privateScreenshots],
               image: chatScreenshot([("Your Demo Bank code is 482913. Don't share it with anyone.", false)], title: "DemoBank")),
        Sample(name: "screenshot with PIN", expect: [.codes, .privateScreenshots],
               image: chatScreenshot([("what's the door code again?", true), ("PIN for the door is 7302, don't tell anyone", false)], title: "Alex")),
        Sample(name: "banking app screenshot", expect: [.bankDetails, .privateScreenshots],
               image: chatScreenshot([("Current account £2,341.10", false), ("Sort code 20-00-00 Account 31926819", false),
                                      ("Available to spend £2,141.10", false)], title: "Demo Bank")),
        Sample(name: "password note", expect: [.secrets], image: note(["wifi password:", "Tr0ub4dor&3"])),
        Sample(name: "login note", expect: [.secrets], image: note(["netflix", "user: sam@example.com", "password: Hunter22!x"], color: (0.7, 0.9, 1))),
        Sample(name: "SSN note", expect: [.governmentIDs], image: note(["SSN 078-05-1120", "for the form"])),
    ]}

    static var harmlessText: [Sample] {[
        Sample(name: "coffee meme", expect: [], image: meme(top: "WHEN THE COFFEE", bottom: "MACHINE IS FIXED", bg: (0.3, 0.5, 0.8))),
        Sample(name: "monday meme", expect: [], image: meme(top: "MONDAY AGAIN", bottom: "NOBODY ASKED", bg: (0.6, 0.3, 0.6))),
        Sample(name: "birthday card", expect: [], image: meme(top: "HAPPY BIRTHDAY", bottom: "SAM!", bg: (0.9, 0.4, 0.4), face: false)),
        Sample(name: "shopping list", expect: [], image: note(["milk", "eggs", "bread", "apples x6"], color: (0.95, 0.95, 0.9))),
        Sample(name: "event poster", expect: [], image: page(["Climbing night", "Thursday 7pm", "All welcome, shoes provided"], header: "Demo Climbing Wall", size: 48)),
        Sample(name: "menu", expect: [], image: page(["Soup of the day   £4.50", "Steak pie   £8.95", "Apple crumble   £3.75"], header: "Today's specials", size: 40)),
        Sample(name: "harmless chat screenshot", expect: [],
               image: chatScreenshot([("see you at 7?", false), ("yes! bring snacks", true), ("will do 🍿", false)], title: "Sam")),
        Sample(name: "keep calm poster", expect: [], image: meme(top: "KEEP CALM", bottom: "AND CLIMB ON", bg: (0.7, 0.1, 0.1), face: false)),
    ]}

    /// Ordinary photos that ship with macOS (desktop pictures, user pictures). Never anyone's own files.
    static func systemPhotos(limit: Int = 70) -> [(String, URL)] {
        let fm = FileManager.default
        var urls: [URL] = []
        for dir in ["/Library/User Pictures", "/System/Library/Desktop Pictures", "/System/Library/Desktop Pictures/.thumbnails"] {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { continue }
            for case let u as URL in e where ["heic", "jpg", "jpeg", "png", "tif", "tiff"].contains(u.pathExtension.lowercased()) {
                if dir.hasSuffix("Desktop Pictures"), u.path.contains(".thumbnails") { continue }
                urls.append(u)
            }
        }
        // Skip near-identical colour variants (Mac Blue, Mac Pink, …): keep one per base name.
        var seen = Set<String>()
        let unique = urls.sorted { $0.path < $1.path }.filter {
            let base = $0.deletingPathExtension().lastPathComponent.components(separatedBy: " ").first ?? ""
            return $0.path.contains("User Pictures") || seen.insert(base).inserted
        }
        return Array(unique.prefix(limit)).map { ($0.deletingPathExtension().lastPathComponent, $0) }
    }

    // MARK: Encoding

    static func encode(_ img: CGImage, as type: UTType) -> Data {
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        CGImageDestinationFinalize(dst)
        return out as Data
    }

    /// An animated GIF whose first frame is `first`.
    static func gif(_ first: CGImage, then other: CGImage) -> Data {
        let out = NSMutableData()
        let dst = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(dst, first, nil)
        CGImageDestinationAddImage(dst, other, nil)
        CGImageDestinationFinalize(dst)
        return out as Data
    }
}
