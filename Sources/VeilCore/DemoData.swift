import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

/// Builds a fake Messages database with the same schema shape as the real chat.db.
/// Used by the tests and by `Veil --demo`. Every message in a chat that should stay
/// private contains the word "SECRET", so tests can assert it never appears in any output.
public enum DemoData {
    public static let contacts: [String: String] = [
        "+15550100001": "Mom", "+15550100002": "Alex Chen", "+15550100003": "Dr. Rivera",
        "+15550100004": "Sam Patel", "alex@example.com": "Alex Chen",
    ]

    /// Chat ids, as they appear to the assistant.
    public enum ID {
        public static let mom = "+15550100001", alex = "+15550100002", therapist = "+15550100003"
        public static let unknown = "+15550199999", climbing = "chat100", family = "chat200"
    }

    /// Permissions used by demo mode (tests set their own).
    public static let demoAccess: [String: ChatAccess] = [
        ID.mom: ChatAccess(read: true, waiting: true, draft: true, send: true, attachments: true),
        ID.alex: ChatAccess(read: true, waiting: true, draft: true, attachments: true),
        ID.climbing: ChatAccess(read: true, waiting: true),
    ]

    @discardableResult
    public static func build(at dir: URL, now: Date = Date()) throws -> (db: URL, attachments: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let atts = dir.appendingPathComponent("Attachments")
        try fm.createDirectory(at: atts, withIntermediateDirectories: true)
        let dbURL = dir.appendingPathComponent("chat.db")
        let db = try SQLiteDB(path: dbURL.path, readOnly: false)

        try db.query("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT)")
        try db.query("CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER, chat_identifier TEXT, service_name TEXT, display_name TEXT)")
        try db.query("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER)")
        try db.query("""
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER,
              date INTEGER, is_from_me INTEGER, cache_has_attachments INTEGER DEFAULT 0, thread_originator_guid TEXT,
              associated_message_guid TEXT, associated_message_type INTEGER DEFAULT 0, item_type INTEGER DEFAULT 0)
            """)
        try db.query("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER)")
        try db.query("CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER)")
        try db.query("CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER)")

        let handles = ["+15550100001", "+15550100002", "+15550100003", "+15550100004", "+15550199999", "alex@example.com"]
        for (i, h) in handles.enumerated() { try db.query("INSERT INTO handle VALUES (?, ?, 'iMessage')", [.int(Int64(i + 1)), .text(h)]) }

        // chat rows: (rowid, guid, style, identifier, display name, handle rowids)
        let chats: [(Int64, String, Int64, String, String?, [Int64])] = [
            (1, "iMessage;-;+15550100001", 45, ID.mom, nil, [1]),
            (2, "SMS;-;+15550100001", 45, ID.mom, nil, [1]),          // same person over SMS
            (3, "iMessage;-;+15550100002", 45, ID.alex, nil, [2]),
            (4, "iMessage;-;+15550100003", 45, ID.therapist, nil, [3]),
            (5, "SMS;-;+15550199999", 45, ID.unknown, nil, [5]),
            (6, "iMessage;+;chat100", 43, ID.climbing, "Climbing crew", [2, 4]),
            (7, "iMessage;+;chat200", 43, ID.family, "Family surprise", [1, 4]),
        ]
        for c in chats {
            try db.query("INSERT INTO chat VALUES (?, ?, ?, ?, ?, ?)", [.int(c.0), .text(c.1), .int(c.2), .text(c.3),
                                                                       .text(c.1.hasPrefix("SMS") ? "SMS" : "iMessage"), c.4.map { .text($0) } ?? .null])
            for h in c.5 { try db.query("INSERT INTO chat_handle_join VALUES (?, ?)", [.int(c.0), .int(h)]) }
        }

        var rowid: Int64 = 0
        func ts(_ hoursAgo: Double) -> Int64 { appleTimestamp(now.addingTimeInterval(-hoursAgo * 3600)) }
        @discardableResult
        func msg(_ chat: Int64, _ from: Int64?, _ text: String?, hoursAgo: Double, body: String? = nil,
                 replyTo: String? = nil, reaction: Int64 = 0, item: Int64 = 0, alsoIn: Int64? = nil) throws -> (Int64, String) {
            rowid += 1
            let guid = "MSG-\(rowid)"
            let blob: SQLiteDB.Value = body.map { .blob(archived($0)) } ?? .null
            try db.query("INSERT INTO message (ROWID, guid, text, attributedBody, handle_id, date, is_from_me, thread_originator_guid, associated_message_type, item_type) VALUES (?,?,?,?,?,?,?,?,?,?)",
                         [.int(rowid), .text(guid), text.map { .text($0) } ?? .null, blob, .int(from ?? 0), .int(ts(hoursAgo)),
                          .int(from == nil ? 1 : 0), replyTo.map { .text($0) } ?? .null, .int(reaction), .int(item)])
            for c in [chat] + (alsoIn.map { [$0] } ?? []) {
                try db.query("INSERT INTO chat_message_join VALUES (?, ?, ?)", [.int(c), .int(rowid), .int(ts(hoursAgo))])
            }
            return (rowid, guid)
        }
        func attach(_ message: Int64, _ id: Int64, _ file: URL, mime: String, name: String) throws {
            if try db.query("SELECT 1 FROM attachment WHERE ROWID = ?", [.int(id)]).isEmpty {
                let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
                try db.query("INSERT INTO attachment VALUES (?, ?, ?, ?, ?, ?)",
                             [.int(id), .text("ATT-\(id)"), .text(file.path), .text(mime), .text(name), .int(size ?? 0)])
            }
            try db.query("INSERT INTO message_attachment_join VALUES (?, ?)", [.int(message), .int(id)])
            try db.query("UPDATE message SET cache_has_attachments = 1 WHERE ROWID = ?", [.int(message)])
        }

        // Family surprise (blocked group with Mom + Sam): everything here is private.
        let (_, secretGuid) = try msg(7, 4, "SECRET plan: surprise party for Jordan on Saturday", hoursAgo: 50)
        let (secretPhotoMsg, _) = try msg(7, 1, nil, hoursAgo: 49, body: "SECRET cake photo")
        try msg(7, 4, nil, hoursAgo: 48, body: "SECRET Don't tell Jordan, they think it's next week")

        // Mom (allowed): two chat rows, iMessage + SMS.
        try msg(1, 1, "Are you coming for dinner Sunday?", hoursAgo: 30)
        try msg(1, nil, "Yes! I'll bring dessert", hoursAgo: 29)
        try msg(2, 1, "Your package arrived here btw", hoursAgo: 28)                        // SMS row
        try msg(1, 1, nil, hoursAgo: 27, body: "Dad says hi and wants the hiking photos")    // attributedBody only
        // A reply whose originator lives in the blocked group. The quote must not resolve.
        try msg(1, 1, "Sounds good", hoursAgo: 26, replyTo: secretGuid)
        try msg(1, nil, "Loved “SECRET plan”", hoursAgo: 25.5, reaction: 2000)              // tapback, ignored
        let (momPhotoMsg, momGuid) = try msg(1, 1, "Here's the garden", hoursAgo: 25)
        try msg(1, nil, "Beautiful!", hoursAgo: 24, replyTo: momGuid)
        let (momForward, _) = try msg(1, 1, "Look what I found", hoursAgo: 23)
        try msg(1, 1, "Call me when you can", hoursAgo: 3)

        // Alex (allowed, waiting on reply).
        try msg(3, nil, "Climbing Thursday?", hoursAgo: 20)
        try msg(3, 2, "Yes, can you book the 7pm slot?", hoursAgo: 6)

        // Therapist (private, everything off).
        try msg(4, 3, "SECRET Reminder: session notes from Tuesday", hoursAgo: 40)
        try msg(4, nil, "SECRET thanks, see you next week", hoursAgo: 39)

        // Unknown number (new chat).
        try msg(5, 5, "SECRET Hi, is this Jordan? Your code is 4417", hoursAgo: 2)

        // Climbing crew (allowed group with Alex + Sam). Sam is also in the blocked group.
        try msg(6, 4, "New route set at the gym", hoursAgo: 10)
        try msg(6, 2, "I'm in for Thursday", hoursAgo: 9)
        try msg(6, nil, "Same", hoursAgo: 8)
        try msg(6, 4, "Group renamed", hoursAgo: 7, item: 2)                                  // system event, ignored

        // Attachments.
        let garden = atts.appendingPathComponent("ab/01/ATT-1/garden.png")
        let cake = atts.appendingPathComponent("cd/02/ATT-2/SECRET-cake.png")
        try writePNG(garden, color: (0.45, 0.65, 0.4)); try writePNG(cake, color: (0.9, 0.5, 0.6))
        try attach(momPhotoMsg, 1, garden, mime: "image/png", name: "garden.png")
        try attach(secretPhotoMsg, 2, cake, mime: "image/png", name: "SECRET-cake.png")
        // Attachment 3: the same file row shared by a blocked-chat message and an allowed one.
        let shared = atts.appendingPathComponent("ef/03/ATT-3/SECRET-shared.png")
        try writePNG(shared, color: (0.3, 0.3, 0.8))
        try attach(secretPhotoMsg, 3, shared, mime: "image/png", name: "SECRET-shared.png")
        try attach(momForward, 3, shared, mime: "image/png", name: "SECRET-shared.png")
        // Attachment 4: points outside the attachments folder (path traversal attempt).
        try db.query("INSERT INTO attachment VALUES (4, 'ATT-4', ?, 'text/plain', 'passwd', 100)", [.text(atts.path + "/../../../etc/passwd")])
        try db.query("INSERT INTO message_attachment_join VALUES (?, 4)", [.int(momForward)])

        return (dbURL, atts)
    }

    /// Demo mode only (not used by tests): sensitive-looking messages in Alex's chat, so the
    /// content filter has something to show. All made up.
    public static func addFilterExamples(db dbURL: URL, now: Date = Date()) throws {
        let db = try SQLiteDB(path: dbURL.path, readOnly: false)
        let examples: [(Double, Bool, String)] = [
            (19, false, "Your verification code is 845221"),
            (18, true, "Thanks! Card for the deposit is 4111 1111 1111 1111"),
            (17, false, "Did you see the senator's speech? Total disgrace"),
            (16, false, "Wifi password: Tr0ub4dor&3"),
            (15, false, "This climbing wall is fucking brilliant"),
            (14, false, "Doctor says the biopsy is clear, phew"),
            (13, true, "Sort code 20-00-00 account 31926819 for the cabin"),
        ]
        var id: Int64 = 9_000
        for (h, fromMe, text) in examples {
            id += 1
            let ts = appleTimestamp(now.addingTimeInterval(-h * 3600))
            try db.query("INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me) VALUES (?,?,?,?,?,?)",
                         [.int(id), .text("DEMO-\(id)"), .text(text), .int(fromMe ? 0 : 2), .int(ts), .int(fromMe ? 1 : 0)])
            try db.query("INSERT INTO chat_message_join VALUES (3, ?, ?)", [.int(id), .int(ts)])
        }
        // Photos for the photo check: a made-up card, a screenshot with a code, and a harmless picture.
        let atts = dbURL.deletingLastPathComponent().appendingPathComponent("Attachments")
        let photos: [(Double, String, CGImage)] = [
            (12.5, "IMG_2041.jpeg", drawCard()),
            (12, "Screenshot 2026-11-12.png", drawScreenshot()),
            (11.5, "IMG_2042.jpeg", drawSunset()),
        ]
        var att: Int64 = 9_100
        for (h, name, img) in photos {
            id += 1; att += 1
            let ts = appleTimestamp(now.addingTimeInterval(-h * 3600))
            try db.query("INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, cache_has_attachments) VALUES (?,?,?,?,?,?,1)",
                         [.int(id), .text("DEMO-\(id)"), .null, .int(2), .int(ts), .int(0)])
            try db.query("INSERT INTO chat_message_join VALUES (3, ?, ?)", [.int(id), .int(ts)])
            let url = atts.appendingPathComponent("demo/\(att)/\(name)")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let type: UTType = name.hasSuffix("png") ? .png : .jpeg
            guard let dst = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dst, img, nil)
            CGImageDestinationFinalize(dst)
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            try db.query("INSERT INTO attachment VALUES (?, ?, ?, ?, ?, ?)",
                         [.int(att), .text("DEMO-ATT-\(att)"), .text(url.path), .text(type.preferredMIMEType ?? "image/jpeg"), .text(name), .int(size ?? 0)])
            try db.query("INSERT INTO message_attachment_join VALUES (?, ?)", [.int(id), .int(att)])
        }
    }

    // MARK: Demo pictures (made up, drawn here)

    private static func canvas(_ w: Int, _ h: Int) -> CGContext {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    }

    private static func draw(_ s: String, _ ctx: CGContext, x: CGFloat, y: CGFloat, size: CGFloat, white: Bool, mono: Bool = false) {
        let font = CTFontCreateWithName((mono ? "Menlo-Regular" : "Helvetica-Bold") as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: white ? 1 : 0.1, alpha: 1),
        ]
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs)), ctx)
    }

    static func drawCard() -> CGImage {
        let ctx = canvas(856, 540)
        ctx.setFillColor(red: 0.1, green: 0.25, blue: 0.6, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 856, height: 540))
        ctx.setFillColor(red: 0.85, green: 0.72, blue: 0.35, alpha: 1); ctx.fill(CGRect(x: 70, y: 290, width: 110, height: 85))
        draw("DEMO BANK", ctx, x: 60, y: 440, size: 44, white: true)
        draw("4242 4242 4242 4242", ctx, x: 60, y: 190, size: 58, white: true, mono: true)
        draw("VALID THRU 12/29", ctx, x: 60, y: 110, size: 26, white: true)
        return ctx.makeImage()!
    }

    static func drawScreenshot() -> CGImage {
        let ctx = canvas(780, 1000)
        ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 780, height: 1000))
        draw("9:41", ctx, x: 60, y: 940, size: 30, white: false)
        ctx.setFillColor(gray: 0.9, alpha: 1)
        ctx.addPath(CGPath(roundedRect: CGRect(x: 30, y: 640, width: 640, height: 150), cornerWidth: 34, cornerHeight: 34, transform: nil)); ctx.fillPath()
        draw("Your Demo Bank code is", ctx, x: 60, y: 730, size: 32, white: false)
        draw("482913. Don't share it.", ctx, x: 60, y: 680, size: 32, white: false)
        return ctx.makeImage()!
    }

    static func drawSunset() -> CGImage {
        let ctx = canvas(800, 600)
        let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [CGColor(red: 0.98, green: 0.6, blue: 0.3, alpha: 1), CGColor(red: 0.45, green: 0.3, blue: 0.6, alpha: 1)] as CFArray,
                           locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: 600), options: [])
        ctx.setFillColor(red: 1, green: 0.85, blue: 0.4, alpha: 1); ctx.fillEllipse(in: CGRect(x: 320, y: 180, width: 160, height: 160))
        ctx.setFillColor(red: 0.15, green: 0.2, blue: 0.3, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 800, height: 200))
        return ctx.makeImage()!
    }

    /// The same encoding Messages uses for `attributedBody`.
    static func archived(_ s: String) -> Data {
        NSArchiver.archivedData(withRootObject: NSAttributedString(string: s))
    }

    private static func writePNG(_ url: URL, color: (CGFloat, CGFloat, CGFloat)) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: color.0, green: color.1, blue: color.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dst)
    }
}

/// Image judge for demo mode and snapshots: sees a mostly-blue picture as a bank card, everything
/// else as clear. Text in demo photos is still read by Vision and checked like a message.
public final class DemoImageClassifier: ImageClassifier, @unchecked Sendable {
    public let engineID = "demo-image/1"
    public let isOnDevice = true
    public var status: ClassifierStatus { .available }
    public init() {}
    public func classify(_ image: CGImage, completion: @escaping @Sendable (Result<ModelVerdict, Error>) -> Void) {
        var v = ModelVerdict.clearPhoto
        var px = [UInt8](repeating: 0, count: 4)
        if let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            if Int(px[2]) > Int(px[0]) + 60 { v.levels[.paymentCards] = .strong }
        }
        completion(.success(v))
    }
}

/// Keyword judge for demo mode and snapshots, so they're instant and repeatable.
/// The real app uses `AppleOnDeviceClassifier`.
public final class DemoClassifier: ContentClassifier, @unchecked Sendable {
    public let engineID = "demo/1"
    public let isOnDevice = true
    public var status: ClassifierStatus { .available }
    public init() {}
    static let rules: [(String, FilterCategory)] = [
        ("election", .politics), ("senator", .politics), ("biopsy", .health), ("doctor", .health),
        ("overdrawn", .moneyWorries), ("idiot", .conflict),
    ]
    public func classify(_ items: [ClassifierItem], completion: @escaping @Sendable (Result<[Int64: ModelVerdict], Error>) -> Void) {
        var out: [Int64: ModelVerdict] = [:]
        for i in items {
            var v = ModelVerdict.clear
            for (k, c) in Self.rules where i.text.lowercased().contains(k) { v.levels[c] = .strong }
            out[i.id] = v
        }
        completion(.success(out))
    }
}
