import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VeilCore

// Photo checks (Photos & files set to Check). The image model is always a fake here; text in
// photos is read by Apple's Vision (on-device) or a fake. Every photo is drawn by the tests.

/// Stand-in for the on-device image model. Judges by a photo's average colour, and can fail in
/// every way the real one can.
final class FakeImageClassifier: ImageClassifier, @unchecked Sendable {
    enum Behavior { case normal, error, refuse, hang, unsure, partial, unavailable }
    private let lock = NSLock()
    private var _behavior: Behavior = .normal
    private var _calls = 0
    var behavior: Behavior { get { lock.lock(); defer { lock.unlock() }; return _behavior } set { lock.lock(); _behavior = newValue; lock.unlock() } }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
    var engineID = "fake-image/1"
    var isOnDevice = true
    var status: ClassifierStatus { behavior == .unavailable ? .unavailable("Apple Intelligence is turned off.") : .available }

    /// Red = a bank card, purple = nudity, anything else is clear.
    static func judge(_ img: CGImage) -> ModelVerdict {
        var v = ModelVerdict.clearPhoto
        let (r, g, b) = averageColor(img)
        if r > 200 && g < 60 && b < 60 { v.levels[.paymentCards] = .strong }
        if r > 100 && b > 100 && g < 40 { v.levels[.nudity] = .strong }
        return v
    }

    func classify(_ image: CGImage, completion: @escaping @Sendable (Result<ModelVerdict, Error>) -> Void) {
        lock.lock(); _calls += 1; let b = _behavior; lock.unlock()
        switch b {
        case .normal: completion(.success(Self.judge(image)))
        case .error, .unavailable: completion(.failure(FakeClassifier.Failure()))
        case .refuse: completion(.failure(ImageCheckRefused()))
        case .hang: return
        case .unsure: completion(.success(ModelVerdict(Dictionary(uniqueKeysWithValues: ModelVerdict.clearPhoto.levels.keys.map { ($0, ConcernLevel.unsure) }))))
        case .partial: completion(.success(ModelVerdict([.paymentCards: .none, .idDocuments: .none])))
        }
    }
}

func averageColor(_ img: CGImage) -> (Int, Int, Int) {
    var px = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .medium
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    return (Int(px[0]), Int(px[1]), Int(px[2]))
}

final class FakeRecognizer: TextRecognizer, @unchecked Sendable {
    var engineID = "fake-ocr/1"
    var text = ""
    var fails = false
    func recognize(_ image: CGImage) throws -> String {
        if fails { throw FakeClassifier.Failure() }
        return text
    }
}

final class FakeNudity: NudityDetector, @unchecked Sendable {
    var isEnabled: Bool
    var sensitive: Bool
    private(set) var calls = 0
    init(enabled: Bool, sensitive: Bool) { isEnabled = enabled; self.sensitive = sensitive }
    func analyze(_ image: CGImage, completion: @escaping @Sendable (Bool?) -> Void) { calls += 1; completion(sensitive) }
}

/// Mom's chat (row 1) has everything on, the filter on, and the standard settings (photos: Check).
final class PhotoHarness {
    static let momFiltered = Harness.defaultAccess.merging([
        ID.mom: ChatAccess(read: true, waiting: true, draft: true, send: true, attachments: true, filtered: true),
    ]) { $1 }

    let f: FilterHarness
    let image = FakeImageClassifier()
    private var nextAtt: Int64 = 500
    var gate: Gate { f.gate }

    init(access: [String: ChatAccess] = PhotoHarness.momFiltered, recognizer: TextRecognizer? = FakeRecognizer(),
         nudity: NudityDetector? = nil, imageEngine: Bool = true) throws {
        f = try FilterHarness(access: access, imageClassifier: imageEngine ? image : nil, recognizer: recognizer, nudity: nudity)
        f.gate.photos.modelTimeout = 3
        f.gate.photos.onDemandTimeout = 5
    }

    static func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, size: Int = 64) -> CGImage {
        let c = PhotoFixtures.Canvas(size, size, bg: (r, g, b)); return c.image
    }
    static let red = solid(1, 0, 0), green = solid(0.2, 0.7, 0.3), purple = solid(0.7, 0, 0.7)

    /// Adds a message carrying one attachment. Returns the attachment id.
    @discardableResult
    func addPhoto(_ key: String, _ data: Data, ext: String = "png", mime: String? = "image/png", chatRow: Int64 = 1,
                  text: String = "", alsoIn: Int64? = nil) throws -> Int64 {
        let (mid, _) = try f.add(key, text, hoursAgo: 0.2, chatRow: chatRow)
        if let alsoIn { try f.db.query("INSERT INTO chat_message_join VALUES (?, ?, 0)", [.int(alsoIn), .int(mid)]) }
        nextAtt += 1
        let url = f.h.dir.appendingPathComponent("Attachments/t/\(nextAtt)/\(key).\(ext)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        try f.db.query("INSERT INTO attachment VALUES (?, ?, ?, ?, ?, ?)",
                       [.int(nextAtt), .text("T-\(nextAtt)"), .text(url.path), mime.map { .text($0) } ?? .null, .text("\(key).\(ext)"), .int(Int64(data.count))])
        try f.db.query("INSERT INTO message_attachment_join VALUES (?, ?)", [.int(mid), .int(nextAtt)])
        try f.db.query("UPDATE message SET cache_has_attachments = 1 WHERE ROWID = ?", [.int(mid)])
        return nextAtt
    }

    func url(_ id: Int64) throws -> URL {
        let store = try gate.messagesStore()
        let info = try #require(try store.attachment(id: id))
        return try #require(store.safeFileURL(for: info))
    }

    func call(_ tool: String, _ args: JSON = [:]) -> Harness.Out { f.call(tool, args) }
    func get(_ id: Int64) -> Harness.Out { call("get_attachment", ["attachment_id": JSON(id)]) }
    func listed() -> [Int64] {
        call("list_attachments", ["chat_id": .string(ID.mom), "limit": 100]).json["attachments"]?.array?.compactMap { $0["attachment_id"]?.int.map(Int64.init) } ?? []
    }
    func readMom() -> String { call("read_chat", ["chat_id": .string(ID.mom), "limit": 200]).raw }
    /// Checks every photo in Mom's chat now (as the background would).
    func checkAll() { _ = try? gate.photoReview(chatID: ID.mom, timeout: 10) }
    var unavailableText: String { call("get_attachment", ["attachment_id": 99_999]).text }
}

@Suite("Photo check: sharing")
struct PhotoCheckSharingTests {
    @Test func checkIsTheDefaultAndCleanPhotosAreShared() throws {
        let p = try PhotoHarness()
        #expect(p.gate.permissions.state.filterPolicy(for: ID.mom)?.attachments == .check)
        // Not checked yet: left out, and checked in the background. Never refused outright.
        let first = p.call("list_attachments", ["chat_id": .string(ID.mom)])
        #expect(!first.isError)
        #expect(first.json["note"]?.string?.contains("on-device check") == true)
        #expect(!p.readMom().contains("garden.png"))
        // Asking for it waits for the check, then returns the image.
        let photo = p.get(1)
        #expect(!photo.isError)
        #expect(photo.result.content.contains { $0["type"]?.string == "image" })
        #expect(p.listed().contains(1))
        #expect(p.readMom().contains("garden.png"))
        // The note says photos are checked, never which or why.
        let note = p.call("read_chat", ["chat_id": .string(ID.mom)]).json["note"]?.string ?? ""
        #expect(note.contains("on-device check"))
        // A photo also in a chat that doesn't share attachments stays hidden, checked or not.
        #expect(p.get(3).isError)
        #expect(!p.listed().contains(3))
    }

    @Test func flaggedPhotosNeverLeave() throws {
        let p = try PhotoHarness()
        let card = try p.addPhoto("bank-card", PhotoFixtures.encode(PhotoHarness.red, as: .png))
        let out = p.get(card)
        let summary = p.gate.log.all.last { $0.tool == "get_attachment" }?.summary ?? ""
        #expect(out.isError)
        #expect(out.text == p.unavailableText, "a flagged photo must look like any unavailable one")
        #expect(!p.listed().contains(card))
        let raw = p.readMom()
        #expect(!raw.contains("bank-card"))
        #expect(raw.contains("attachments_hidden"))
        // The user's log says it was held back, not why.
        #expect(summary.contains("didn't pass"))
        for word in ["card", "payment", "nudity", "document"] { #expect(!summary.lowercased().contains(word)) }
        // The user sees why.
        let review = try p.gate.photoReview(chatID: ID.mom)
        #expect(review.first { $0.id == card }?.reasons == [.paymentCards])
        #expect(review.first { $0.id == 1 } == nil, "clean photos aren't listed for review")
    }

    @Test func pendingAndFlaggedLookTheSame() throws {
        let p = try PhotoHarness()
        p.image.behavior = .hang
        let pending = try p.addPhoto("a", PhotoFixtures.encode(PhotoHarness.green, as: .png))
        p.gate.photos.onDemandTimeout = 0.2; p.gate.photos.modelTimeout = 0.2
        let a = p.get(pending)
        p.image.behavior = .normal
        let flagged = try p.addPhoto("b", PhotoFixtures.encode(PhotoHarness.red, as: .png))
        p.gate.photos.onDemandTimeout = 5; p.gate.photos.modelTimeout = 3
        let b = p.get(flagged)
        #expect(a.isError && b.isError && a.text == b.text)
        #expect(!p.listed().contains(pending) && !p.listed().contains(flagged))
    }

    @Test func photoOnAWithheldMessageStaysHidden() throws {
        let p = try PhotoHarness()
        let id = try p.addPhoto("view", PhotoFixtures.encode(PhotoHarness.green, as: .png), text: "the senator again")
        p.checkAll()
        #expect(p.get(id).isError)
        #expect(!p.listed().contains(id))
        #expect(!p.readMom().contains("view.png"))
    }

    @Test func everyChatItAppearsInMustAllowIt() throws {
        let p = try PhotoHarness()
        // Also posted in the climbing group, which doesn't share photos.
        let id = try p.addPhoto("shared", PhotoFixtures.encode(PhotoHarness.green, as: .png), alsoIn: 6)
        p.checkAll()
        #expect(p.get(id).isError)
        #expect(!p.listed().contains(id))
    }

    @Test func allowAndWithholdModesBehaveAsBefore() throws {
        let p = try PhotoHarness()
        let card = try p.addPhoto("bank-card", PhotoFixtures.encode(PhotoHarness.red, as: .png))
        var allow = FilterPolicy.standard; allow.attachments = .allow
        try p.gate.setChatFilterPolicy(allow, for: ID.mom)
        #expect(!p.get(card).isError)
        #expect(p.listed().contains(card))
        #expect(p.image.calls == 0, "Allow never runs the photo check")
        var withhold = FilterPolicy.standard; withhold.attachments = .withhold
        try p.gate.setChatFilterPolicy(withhold, for: ID.mom)
        #expect(p.call("list_attachments", ["chat_id": .string(ID.mom)]).isError)
        #expect(p.get(1).isError)
        #expect(p.image.calls == 0)
    }

    @Test func unfilteredChatsAreUntouched() throws {
        let p = try PhotoHarness(access: Harness.defaultAccess)
        let card = try p.addPhoto("bank-card", PhotoFixtures.encode(PhotoHarness.red, as: .png))
        #expect(!p.get(card).isError)
        #expect(p.image.calls == 0)
    }

    @Test func backgroundWarmingChecksRecentPhotos() throws {
        let p = try PhotoHarness()
        try p.addPhoto("view", PhotoFixtures.encode(PhotoHarness.green, as: .png))
        p.gate.warmFilterCache()
        let deadline = Date().addingTimeInterval(10)
        while p.gate.photos.cachedCount < 2 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        #expect(p.gate.photos.cachedCount >= 2)
        // Requests now find them without waiting.
        let calls = p.image.calls
        #expect(p.listed().contains(1))
        #expect(p.image.calls == calls)
    }
}

@Suite("Photo check: what's in the picture")
struct PhotoCheckContentTests {
    /// Real on-device text recognition (Apple Vision) over drawn pictures; the image model sees nothing.
    @Test func textInPhotosGoesThroughThePatternDetectors() throws {
        let p = try PhotoHarness(recognizer: VisionTextRecognizer())
        let card = try p.addPhoto("visa", PhotoFixtures.encode(PhotoFixtures.sensitive[0].image, as: .jpeg), ext: "jpeg", mime: "image/jpeg")
        let code = try p.addPhoto("code", PhotoFixtures.encode(PhotoFixtures.sensitive.first { $0.name == "screenshot with code" }!.image, as: .png))
        let pw = try p.addPhoto("note", PhotoFixtures.encode(PhotoFixtures.sensitive.first { $0.name == "password note" }!.image, as: .jpeg),
                                ext: "jpeg", mime: "image/jpeg")
        let chat = try p.addPhoto("chat", PhotoFixtures.encode(PhotoFixtures.harmlessText.first { $0.name == "harmless chat screenshot" }!.image, as: .png))
        let review = Dictionary(uniqueKeysWithValues: try p.gate.photoReview(chatID: ID.mom, timeout: 30).map { ($0.id, $0) })
        #expect(review[card]?.reasons.contains(.cardNumbers) == true)
        #expect(review[code]?.reasons.contains(.codes) == true)
        #expect(review[pw]?.reasons.contains(.secrets) == true)
        #expect(review[chat] == nil)
        for id in [card, code, pw] { #expect(p.get(id).isError) }
        #expect(!p.get(chat).isError)
        // Mask can't cut a number out of a picture, so Mask withholds too; only Allow lets it through.
        var policy = FilterPolicy.standard
        policy.set(.cardNumbers, .allow)
        try p.gate.setChatFilterPolicy(policy, for: ID.mom)
        #expect(!p.get(card).isError)
        #expect(p.get(code).isError)
    }

    @Test func textInPhotosGoesThroughTheTextModel() throws {
        let ocr = FakeRecognizer()
        ocr.text = "I think the senator is a disgrace"
        let p = try PhotoHarness(recognizer: ocr)
        let id = try p.addPhoto("poster", PhotoFixtures.encode(PhotoHarness.green, as: .png))
        #expect(p.get(id).isError)
        #expect(try p.gate.photoReview(chatID: ID.mom).first { $0.id == id }?.reasons == [.politics])
        // Swearing in a meme isn't a reason to hold a photo back.
        ocr.text = "this is fucking brilliant"; ocr.engineID = "fake-ocr/2"
        #expect(!p.get(id).isError)
        // Text the text model can't judge can't be cleared.
        ocr.text = "a perfectly ordinary caption"; ocr.engineID = "fake-ocr/3"
        p.f.fake.behavior = .error
        #expect(p.get(id).isError)
        p.f.fake.behavior = .normal
        #expect(!p.get(id).isError)
    }

    @Test func ocrTextIsCheckedEvenWithoutATextModel() throws {
        let ocr = FakeRecognizer()
        ocr.text = "Card 4242 4242 4242 4242"
        let p = try PhotoHarness(recognizer: ocr)
        let id = try p.addPhoto("x", PhotoFixtures.encode(PhotoHarness.green, as: .png))
        var policy = FilterPolicy.standard
        for c in FilterCategory.modelCategories { policy.set(c, .allow) }
        try p.gate.setChatFilterPolicy(policy, for: ID.mom)
        #expect(p.get(id).isError)
        ocr.text = "see you at 7"; ocr.engineID = "fake-ocr/2"
        #expect(!p.get(id).isError)
    }

    @Test func nudityFromSensitiveContentAnalysis() throws {
        let sca = FakeNudity(enabled: true, sensitive: true)
        let p = try PhotoHarness(nudity: sca)
        #expect(p.get(1).isError)
        #expect(sca.calls == 1)
        #expect(try p.gate.photoReview(chatID: ID.mom).first { $0.id == 1 }?.reasons == [.nudity])
        // Turned off on this Mac: skipped, never waited on.
        let off = FakeNudity(enabled: false, sensitive: true)
        let q = try PhotoHarness(nudity: off)
        #expect(!q.get(1).isError)
        #expect(off.calls == 0)
        // The model's own judgement still withholds.
        let purple = try q.addPhoto("p", PhotoFixtures.encode(PhotoHarness.purple, as: .png))
        #expect(q.get(purple).isError)
    }
}

@Suite("Photo check: fails closed")
struct PhotoCheckFailClosedTests {
    func check(_ behavior: FakeImageClassifier.Behavior, _ what: String, recognizerFails: Bool = false) throws {
        let ocr = FakeRecognizer(); ocr.fails = recognizerFails
        let p = try PhotoHarness(recognizer: ocr)
        p.image.behavior = behavior
        p.gate.photos.onDemandTimeout = 0.4; p.gate.photos.modelTimeout = 0.3
        #expect(p.get(1).isError, "\(what): photo was shared")
        #expect(!p.listed().contains(1), "\(what): photo was listed")
        #expect(!p.readMom().contains("garden.png"), "\(what): photo was in read_chat")
        let o = try p.gate.photoReview(chatID: ID.mom, timeout: 1).first { $0.id == 1 }?.outcome
        #expect(o?.withheld == true && o?.notCleared == true, "\(what)")
    }

    @Test func modelError() throws { try check(.error, "error") }
    @Test func modelTimeout() throws { try check(.hang, "timeout") }
    @Test func unsureAnswers() throws { try check(.unsure, "unsure") }
    @Test func missingCategories() throws { try check(.partial, "partial answer") }
    @Test func appleIntelligenceOff() throws { try check(.unavailable, "unavailable") }
    @Test func textRecognitionFails() throws { try check(.normal, "ocr failure", recognizerFails: true) }

    @Test func refusalWithholdsAndIsRemembered() throws {
        let p = try PhotoHarness()
        p.image.behavior = .refuse
        #expect(p.get(1).isError)
        #expect(p.get(1).isError)
        #expect(p.image.calls == 1, "a refusal is a verdict and is cached")
        let o = try #require(try p.gate.photoReview(chatID: ID.mom).first { $0.id == 1 })
        #expect(o.outcome.problem == .refused)
        #expect(FilterReviewLabels.problem(o.outcome) == "refused")
    }

    @Test func noImageModelAtAll() throws {
        let p = try PhotoHarness(imageEngine: false)
        #expect(p.get(1).isError)
        #expect(!p.listed().contains(1))
        #expect(!p.gate.photos.status.isAvailable)
    }

    @Test func noTextRecognition() throws {
        let p = try PhotoHarness(recognizer: nil)
        #expect(p.get(1).isError)
        #expect(p.image.calls == 0)
    }

    @Test func offDeviceImageEngineIsNeverUsed() throws {
        let p = try PhotoHarness()
        p.image.isOnDevice = false
        #expect(p.get(1).isError)
        #expect(p.image.calls == 0)
    }

    @Test func badFilesAreWithheld() throws {
        let p = try PhotoHarness()
        let junk = try p.addPhoto("junk", Data("definitely not a png".utf8))
        let video = try p.addPhoto("clip", Data(repeating: 7, count: 2000), ext: "mp4", mime: "video/mp4")
        let audio = try p.addPhoto("memo", Data(repeating: 7, count: 2000), ext: "m4a", mime: "audio/x-m4a")
        let text = try p.addPhoto("notes", Data("wifi password: hunter2".utf8), ext: "txt", mime: "text/plain")
        let big = try p.addPhoto("big", PhotoFixtures.encode(PhotoHarness.solid(0.2, 0.6, 0.3, size: 400), as: .png))
        p.gate.photos.maxFileBytes = 1500
        for id in [junk, video, audio, text, big] {
            #expect(p.get(id).isError, "attachment \(id) was shared")
            #expect(!p.listed().contains(id))
        }
        #expect(!p.get(video).raw.contains("clip"))
        let review = Dictionary(uniqueKeysWithValues: try p.gate.photoReview(chatID: ID.mom).map { ($0.id, $0.outcome) })
        #expect(review[junk]?.problem == .unreadable || review[junk]?.problem == .unsupported)
        #expect(review[big]?.problem == .tooLarge)
        #expect(review[video] == nil && review[text] == nil, "only photos are listed for review")
        // The image model never saw any of them.
        #expect(p.image.calls <= 1)   // the garden photo, if the review checked it
    }

    @Test func missingFileIsWithheld() throws {
        let p = try PhotoHarness()
        let id = try p.addPhoto("gone", PhotoFixtures.encode(PhotoHarness.green, as: .png))
        try FileManager.default.removeItem(at: try p.url(id))
        #expect(p.get(id).isError)
        #expect(!p.listed().contains(id))
    }
}

@Suite("Photo check: formats and cache")
struct PhotoCheckCacheTests {
    @Test func formats() throws {
        let p = try PhotoHarness()
        let jpeg = try p.addPhoto("j", PhotoFixtures.encode(PhotoHarness.green, as: .jpeg), ext: "jpeg", mime: "image/jpeg")
        let heic = try p.addPhoto("h", PhotoFixtures.encode(PhotoHarness.solid(0.2, 0.7, 0.3, size: 256), as: .heic), ext: "heic", mime: "image/heic")
        // A sticker or GIF: the first frame is what's checked.
        let gifBad = try p.addPhoto("g1", PhotoFixtures.gif(PhotoHarness.red, then: PhotoHarness.green), ext: "gif", mime: "image/gif")
        let gifOK = try p.addPhoto("g2", PhotoFixtures.gif(PhotoHarness.green, then: PhotoHarness.green), ext: "gif", mime: "image/gif")
        // No MIME type: judged by the file extension.
        let noMime = try p.addPhoto("n", PhotoFixtures.encode(PhotoHarness.green, as: .png), mime: nil)
        for id in [jpeg, heic, gifOK, noMime] { #expect(!p.get(id).isError, "attachment \(id) was withheld") }
        #expect(p.get(gifBad).isError)
    }

    @Test func verdictsAreCachedByContent() throws {
        let p = try PhotoHarness()
        let id = try p.addPhoto("pic", PhotoFixtures.encode(PhotoHarness.green, as: .png))
        #expect(!p.get(id).isError)
        #expect(!p.get(id).isError)
        #expect(p.image.calls == 1)
        // The file changes: checked again, and the new verdict applies.
        try PhotoFixtures.encode(PhotoHarness.red, as: .png).write(to: try p.url(id))
        #expect(p.get(id).isError)
        #expect(p.image.calls == 2)
        // A new engine version: checked again.
        p.image.engineID = "fake-image/2"
        #expect(p.get(id).isError)
        #expect(p.image.calls == 3)
        // Settings changes apply to cached verdicts without checking again.
        var policy = FilterPolicy.standard
        policy.set(.paymentCards, .allow)
        try p.gate.setChatFilterPolicy(policy, for: ID.mom)
        #expect(!p.get(id).isError)
        #expect(p.image.calls == 3)
        // Only verdicts are kept: no pixels, no recognised text.
        let mirror = String(describing: p.gate.photos.cached(PhotoChecker.Request(id: id, url: try p.url(id)))!)
        #expect(!mirror.contains("Data") && !mirror.contains("CGImage"))
    }

    @Test func whatIsCheckedIsWhatIsSent() throws {
        // The bytes handed to the assistant are the bytes that were checked.
        let p = try PhotoHarness()
        let id = try p.addPhoto("pic", PhotoFixtures.encode(PhotoHarness.green, as: .png))
        let out = p.get(id)
        let b64 = try #require(out.result.content.first { $0["type"]?.string == "image" }?["data"]?.string)
        let img = try #require(Data(base64Encoded: b64).flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let (r, g, _) = averageColor(img)
        #expect(g > r)
    }

    @Test func refusedVerdictUnaffectedByStrictness() {
        var p = FilterPolicy.standard
        for s in FilterStrictness.allCases {
            p.strictness = s
            #expect(PhotoChecker.decide(PhotoVerdict(problem: .refused), policy: p, isPhoto: true).withheld)
            #expect(PhotoChecker.decide(nil, policy: p, isPhoto: true).pending)
            #expect(PhotoChecker.decide(PhotoVerdict(seen: .clearPhoto), policy: p, isPhoto: false).withheld)
            #expect(!PhotoChecker.decide(PhotoVerdict(seen: .clearPhoto), policy: p, isPhoto: true).withheld)
        }
        // A clear photo whose text couldn't be judged isn't cleared.
        let v = PhotoVerdict(seen: .clearPhoto, hasText: true, textVerdict: nil)
        #expect(PhotoChecker.decide(v, policy: .standard, isPhoto: true).notCleared)
    }
}

@Suite("Photo check: the user's review")
struct PhotoCheckReviewTests {
    @Test func allowThisPhoto() throws {
        let p = try PhotoHarness()
        let card = try p.addPhoto("bank-card", PhotoFixtures.encode(PhotoHarness.red, as: .png))
        #expect(p.get(card).isError)
        try p.gate.setPhotoAllowed(true, attachment: card, in: ID.mom)
        #expect(!p.get(card).isError)
        #expect(p.listed().contains(card))
        let item = try #require(try p.gate.photoReview(chatID: ID.mom).first { $0.id == card })
        #expect(item.allowedByUser && item.reasons == [.paymentCards])
        #expect(p.gate.photoThumbnail(attachmentID: card, chatID: ID.mom) != nil)
        #expect(p.gate.photoThumbnail(attachmentID: card, chatID: ID.alex) == nil, "thumbnails only for the chat's own photos")
        try p.gate.setPhotoAllowed(false, attachment: card, in: ID.mom)
        #expect(p.get(card).isError)
        // "Always allow bank cards here".
        try p.gate.alwaysAllow(.paymentCards, in: ID.mom)
        #expect(!p.get(card).isError)
        // Saved in the signed settings.
        try p.gate.setPhotoAllowed(true, attachment: card, in: ID.mom)
        let reloaded = PermissionStore(url: p.f.h.permissionsURL, secrets: p.f.h.secrets)
        #expect(reloaded.integrity == .ok)
        #expect(reloaded.state.chats[ID.mom]?.filterAllowedPhotos == [card])
    }

    @Test func mcpCannotAllowPhotos() throws {
        let p = try PhotoHarness()
        let card = try p.addPhoto("bank-card", PhotoFixtures.encode(PhotoHarness.red, as: .png))
        let before = p.gate.permissions.state
        for t in ["allow_photo", "set_photo_allowed", "photo_review", "set_filter"] + MCPServer.tools.compactMap({ $0["name"]?.string }) {
            p.call(t, ["chat_id": .string(ID.mom), "attachment_id": JSON(card), "allow": true, "allowed": true, "mode": "allow"])
        }
        #expect(p.gate.permissions.state.generation == before.generation)
        #expect(p.get(card).isError)
    }
}

@Suite("Photo check: signed settings")
struct PhotoCheckSettingsTests {
    @Test func oldPolicyValuesDecodeAndReencodeIdentically() throws {
        for mode in ["allow", "withhold", "check"] {
            let json = #"{"actions":{"codes":"mask"},"attachments":"\#(mode)","strictness":"balanced"}"#
            let p = try JSONDecoder().decode(FilterPolicy.self, from: Data(json.utf8))
            #expect(p.attachments.rawValue == mode)
            #expect(p.action(.paymentCards) == .withhold, "photo categories missing from old files fall back to Withhold")
            let again = try JSONEncoder.sorted.encode(p)
            let original = try JSONEncoder.sorted.encode(try JSONDecoder().decode(JSON.self, from: Data(json.utf8)))
            #expect(again == original)
        }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(FilterPolicy.self, from: Data(#"{"actions":{},"attachments":"mask","strictness":"balanced"}"#.utf8)) }
    }

    @Test func savedChoicesAreKeptAndCheckIsTheNewDefault() throws {
        // A permissions file from before Check existed: a default profile that withheld photos, a chat
        // with its own settings allowing them, and a filtered chat on the default profile.
        let old = #"""
        {"chats":{"a":{"attachments":true,"draft":false,"filterPolicy":{"actions":{"codes":"mask"},"attachments":"allow","strictness":"balanced"},"filtered":true,"hidden":false,"read":true,"send":false,"waiting":false},
                  "b":{"attachments":true,"draft":false,"filtered":true,"hidden":false,"read":true,"send":false,"waiting":false}},
         "filterProfile":{"actions":{"politics":"allow"},"attachments":"withhold","strictness":"strict"},
         "generation":4,"paused":false,"reviewed":["a","b"]}
        """#
        let s = try JSONDecoder().decode(PermissionState.self, from: Data(old.utf8))
        #expect(s.filterPolicy(for: "a")?.attachments == .allow)
        #expect(s.filterPolicy(for: "b")?.attachments == .withhold, "a saved default profile keeps its choice")
        let a = try JSONEncoder.sorted.encode(s)
        #expect(a == (try JSONEncoder.sorted.encode(try JSONDecoder().decode(JSON.self, from: Data(old.utf8)))))
        #expect(!String(decoding: a, as: UTF8.self).contains("filterAllowedPhotos"))
        // With no saved default profile, filtered chats check photos.
        var fresh = s; fresh.filterProfile = nil
        #expect(fresh.filterPolicy(for: "b")?.attachments == .check)
    }

    @Test func handEditedPhotoModeFailsClosed() throws {
        let p = try PhotoHarness()
        var policy = FilterPolicy.standard; policy.attachments = .check
        policy.set(.nudity, .withhold)
        try p.gate.setChatFilterPolicy(policy, for: ID.mom)
        var text = try String(contentsOf: p.f.h.permissionsURL, encoding: .utf8)
        #expect(text.contains("\"attachments\" : \"check\""))
        text = text.replacingOccurrences(of: "\"attachments\" : \"check\"", with: "\"attachments\" : \"allow\"")
        try text.write(to: p.f.h.permissionsURL, atomically: true, encoding: .utf8)
        let reopened = PermissionStore(url: p.f.h.permissionsURL, secrets: p.f.h.secrets)
        if case .tampered = reopened.integrity {} else { Issue.record("hand-edited photo mode was accepted") }
        #expect(reopened.state.access(ID.mom).attachments == false)
    }

    @Test func photoEnginesAreOnDeviceOnly() throws {
        #expect(AppleOnDeviceImageClassifier().isOnDevice)
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = root.appendingPathComponent("Sources/VeilCore")
        for name in ["PhotoCheck.swift", "AppleImageClassifier.swift"] {
            let text = try String(contentsOf: sources.appendingPathComponent(name), encoding: .utf8)
            for net in ["URLSession", "import Network", "NWConnection", "URLRequest", "CFSocket", "PrivateCloud"] {
                #expect(!text.contains(net), "\(name) uses \(net)")
            }
        }
        let apple = try String(contentsOf: sources.appendingPathComponent("AppleImageClassifier.swift"), encoding: .utf8)
        #expect(apple.contains("SystemLanguageModel(useCase:"))
        #expect(apple.components(separatedBy: "LanguageModelSession(model: model").count == 2)
    }
}

/// Plain labels for review outcomes, so tests can check what the user is told without the UI target.
enum FilterReviewLabels {
    static func problem(_ o: PhotoOutcome) -> String? { o.problem?.rawValue }
}

@Suite("Photo check: demo data")
struct PhotoCheckDemoTests {
    @Test func demoPhotosAreChecked() throws {
        let h = try Harness(access: DemoData.demoAccess, classifier: DemoClassifier(), imageClassifier: DemoImageClassifier())
        try DemoData.addFilterExamples(db: h.dir.appendingPathComponent("chat.db"))
        try h.gate.setFiltered(true, for: ID.alex)
        let review = try h.gate.photoReview(chatID: ID.alex, timeout: 30)
        #expect(review.count == 2)
        #expect(review.allSatisfy { !$0.outcome.pending })
        #expect(review.contains { $0.reasons.contains(.paymentCards) })
        #expect(review.contains { $0.reasons.contains(.codes) })
    }
}
