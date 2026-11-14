import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Photo checking for filtered chats whose "Photos & files" is set to Check. Each photo is looked at
// on this Mac and shared only if it's clean. Three looks, and any one of them can withhold:
//
//   1. An `ImageClassifier` (Apple's on-device model, which can see images) rates the photo for ID
//      documents, payment cards, personal documents, private screenshots and nudity, plus the
//      judgement topics used for message text.
//   2. A `TextRecognizer` (Apple's Vision text recognition) reads any text in the photo. That text
//      goes through the same pattern detectors and text model as messages, so a card number, code
//      or password visible in a photo withholds it.
//   3. A `NudityDetector` (Apple's SensitiveContentAnalysis) when this Mac allows Veil to use it.
//      Optional: when it's unavailable the model and the fail-closed rules still apply.
//
// It fails closed: no model, no vision support, an error, a timeout, a refusal, an "unsure" answer,
// an unreadable, unsupported or oversized file, or a photo that simply hasn't been checked yet all
// mean the photo is withheld. Videos, audio and other files are never shared in Check mode.
//
// Verdicts are cached in memory only (never pixels or recognised text), keyed by attachment id,
// a hash of the file's contents and the engine versions, so an edited file or a new engine is
// checked again. A verdict doesn't depend on settings, so changing settings applies instantly.

/// Something that looks at one image. Engines must run on this Mac.
public protocol ImageClassifier: AnyObject, Sendable {
    /// Changes whenever results could change (model, prompt, schema), so cached verdicts are redone.
    var engineID: String { get }
    /// Must be true. Photos are never checked by an engine that sends them anywhere.
    var isOnDevice: Bool { get }
    var status: ClassifierStatus { get }
    /// Rates the image for the photo and judgement categories. Missing categories count as unsure.
    /// Fail with `ImageCheckRefused` when the model refused to look (for example a guardrail): the
    /// photo is withheld and that answer is remembered. Any other failure is retried later.
    /// May call back on any thread, at most once.
    func classify(_ image: CGImage, completion: @escaping @Sendable (Result<ModelVerdict, Error>) -> Void)
}

/// The image model refused to judge a photo. Treated as "withhold".
public struct ImageCheckRefused: Error, Equatable {
    public init() {}
}

/// Reads text in an image, on this Mac.
public protocol TextRecognizer: AnyObject, Sendable {
    var engineID: String { get }
    func recognize(_ image: CGImage) throws -> String
}

/// An optional extra check for nudity (Apple's SensitiveContentAnalysis).
public protocol NudityDetector: AnyObject, Sendable {
    /// False when this Mac doesn't let Veil use it. Then it's skipped, never waited on.
    var isEnabled: Bool { get }
    /// true = sensitive, false = not, nil = couldn't tell (ignored). At most once, any thread.
    func analyze(_ image: CGImage, completion: @escaping @Sendable (Bool?) -> Void)
}

/// Everything learned about one photo. Doesn't depend on settings. Never holds text or pixels.
public struct PhotoVerdict: Equatable, Sendable {
    public enum Problem: String, Sendable {
        /// Not an image format Veil can read.
        case unsupported
        /// Bigger than `PhotoChecker.maxFileBytes` or `maxPixels`.
        case tooLarge
        /// The file couldn't be opened or decoded.
        case unreadable
        /// The model refused to look at it.
        case refused
    }
    public var problem: Problem?
    /// The image model's ratings (photo and judgement categories).
    public var seen = ModelVerdict([:])
    /// Pattern categories found in the photo's text.
    public var textFound: Set<FilterCategory> = []
    /// The photo has readable text.
    public var hasText = false
    /// The text model's ratings for that text. nil when there's no text, or no text model was usable.
    public var textVerdict: ModelVerdict?
    /// SensitiveContentAnalysis flagged it.
    public var flaggedSensitive = false

    public init(problem: Problem? = nil, seen: ModelVerdict = ModelVerdict([:]), textFound: Set<FilterCategory> = [],
                hasText: Bool = false, textVerdict: ModelVerdict? = nil, flaggedSensitive: Bool = false) {
        self.problem = problem; self.seen = seen; self.textFound = textFound
        self.hasText = hasText; self.textVerdict = textVerdict; self.flaggedSensitive = flaggedSensitive
    }
}

extension ModelVerdict {
    /// Nothing found in any photo or judgement category.
    public static let clearPhoto = ModelVerdict(Dictionary(uniqueKeysWithValues:
        (FilterCategory.photoCategories + FilterCategory.modelCategories).map { ($0, ConcernLevel.none) }))
}

/// What the filter decided for one photo or file.
public struct PhotoOutcome: Equatable, Sendable {
    public var withheld = true
    /// Why (the user-only). Never sent to the assistant or written to the log.
    public var reasons: Set<FilterCategory> = []
    /// Withheld because it couldn't be checked (no model, refusal, unsure, unreadable…).
    public var notCleared = false
    /// Not checked yet.
    public var pending = false
    public var problem: PhotoVerdict.Problem?
    /// Not a photo: in Check mode, only photos are shared.
    public var notAPhoto = false
    public var allowedByUser = false
    public static let shown = PhotoOutcome(withheld: false)
}

public final class PhotoChecker: @unchecked Sendable {
    public let classifier: ImageClassifier?
    public let recognizer: TextRecognizer?
    public let nudity: NudityDetector?
    /// The message filter, for the text found in photos (its detectors and its model). Held strongly:
    /// background checks can outlive a request, and the filter never points back here.
    let textFilter: ContentFilter

    /// Bump when the photo pipeline changes, so old verdicts are redone.
    public static let version = 1
    /// Bigger files aren't checked (and so are withheld).
    public var maxFileBytes = 50 * 1024 * 1024
    public static let maxPixels = 120_000_000
    /// Longest side of the image the model and text recognition see.
    public static let workingSize = 1536
    /// How long `get_attachment` waits for an unchecked photo before withholding it.
    public var onDemandTimeout: TimeInterval = 12
    /// The longest any one model call may take. Slower answers count as failures.
    public var modelTimeout: TimeInterval = 45
    /// A photo whose check failed isn't retried in the background for this long.
    public var retryAfter: TimeInterval = 300
    static let maxRunning = 2
    static let maxQueued = 400

    private let lock = NSLock()
    private var cache: [String: PhotoVerdict] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 20_000
    private var digests: [String: (stamp: String, digest: String)] = [:]
    private var failedAt: [String: Date] = [:]
    private var jobs: [String: Job] = [:]
    private var queued: [Job] = []
    private var running = 0
    private var prewarmed = false

    init(classifier: ImageClassifier?, recognizer: TextRecognizer?, nudity: NudityDetector?, textFilter: ContentFilter) {
        self.classifier = classifier; self.recognizer = recognizer; self.nudity = nudity; self.textFilter = textFilter
    }

    // MARK: Status

    /// The image model, only if it's on-device and ready, and text recognition exists.
    var usableClassifier: ImageClassifier? {
        guard let c = classifier, c.isOnDevice, c.status.isAvailable, recognizer != nil else { return nil }
        return c
    }

    /// The user-facing status of photo checking.
    public var status: ClassifierStatus {
        guard let c = classifier else { return .unavailable("No on-device image model is set up on this Mac.") }
        guard c.isOnDevice else { return .unavailable("The configured image model isn't on-device, so it's never used.") }
        guard recognizer != nil else { return .unavailable("Text recognition isn't available.") }
        return c.status
    }

    /// Changes whenever any part of the pipeline would answer differently, so verdicts are redone.
    var engineKey: String? {
        guard let c = usableClassifier, let r = recognizer else { return nil }
        let text = textFilter.usableClassifier?.engineID ?? "no-text-model"
        let sca = nudity?.isEnabled == true ? "sca" : "no-sca"
        return "\(c.engineID)|\(r.engineID)|\(text)|\(sca)|v\(Self.version)"
    }

    /// Runs text recognition once on a blank picture, in the background. The first recognition in a
    /// new build of the app compiles Apple's model for this Mac, which can take a minute or more;
    /// doing it at launch means the first real photo doesn't wait for it.
    public func prewarm() {
        guard let recognizer else { return }
        lock.lock(); defer { lock.unlock() }
        guard !prewarmed else { return }
        prewarmed = true
        DispatchQueue.global(qos: .utility).async {
            let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            if let img = ctx?.makeImage() { _ = try? recognizer.recognize(img) }
        }
    }

    // MARK: Requests

    /// One photo to check: its attachment id, and either the file or its bytes already read.
    public struct Request: Sendable {
        public let id: Int64
        public let url: URL
        /// The exact bytes that will be shared, so what's checked is what's sent.
        public let data: Data?
        public init(id: Int64, url: URL, data: Data? = nil) { self.id = id; self.url = url; self.data = data }
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// A content hash of the file, remembered by size, change time and inode so it's read only when it changes.
    func digest(of r: Request) -> String? {
        if let d = r.data { return Self.digest(d) }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: r.url.path),
              let size = attrs[.size] as? Int else { return nil }
        guard size <= maxFileBytes else { return "too-large-\(size)" }
        let stamp = "\(size)|\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)|\(attrs[.systemFileNumber] ?? 0)"
        lock.lock()
        if let m = digests[r.url.path], m.stamp == stamp { lock.unlock(); return m.digest }
        lock.unlock()
        guard let data = try? Data(contentsOf: r.url, options: .mappedIfSafe) else { return nil }
        let d = Self.digest(data)
        lock.lock(); digests[r.url.path] = (stamp, d); if digests.count > 50_000 { digests.removeAll() }; lock.unlock()
        return d
    }

    func cacheKey(_ r: Request) -> String? {
        guard let engine = engineKey, let d = digest(of: r) else { return nil }
        return "\(engine)|\(r.id)|\(d)"
    }

    /// The cached verdict, if this photo (as it is now) was already checked by the current engines.
    public func cached(_ r: Request) -> PhotoVerdict? {
        guard let k = cacheKey(r) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return cache[k]
    }

    public var cachedCount: Int { lock.lock(); defer { lock.unlock() }; return cache.count }
    public func clearCache() { lock.lock(); cache = [:]; cacheOrder = []; failedAt = [:]; lock.unlock() }

    private func store(_ v: PhotoVerdict, for key: String) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = v
        if cacheOrder.count > cacheLimit {
            let drop = cacheOrder.prefix(cacheOrder.count - cacheLimit)
            for k in drop { cache[k] = nil }
            cacheOrder.removeFirst(drop.count)
        }
    }

    /// Checks photos, waiting at most `timeout` seconds overall, and returns the verdicts that are
    /// ready. Anything slower keeps going in the background and is cached for next time.
    /// `urgent` requests jump ahead of background work.
    @discardableResult
    public func check(_ requests: [Request], timeout: TimeInterval, urgent: Bool = false) -> [Int64: PhotoVerdict] {
        var out: [Int64: PhotoVerdict] = [:]
        var waiting: [(Int64, String)] = []
        let done = NSCondition()
        var remaining = 0
        for r in requests {
            guard let k = cacheKey(r) else { continue }
            lock.lock(); let hit = cache[k]; lock.unlock()
            if let hit { out[r.id] = hit; continue }
            waiting.append((r.id, k))
            done.lock(); remaining += 1; done.unlock()
            submit(r, key: k, urgent: urgent) { done.lock(); remaining -= 1; done.broadcast(); done.unlock() }
        }
        guard !waiting.isEmpty else { return out }
        if timeout > 0 {
            let deadline = Date().addingTimeInterval(timeout)
            done.lock()
            while remaining > 0 { if !done.wait(until: deadline) { break } }
            done.unlock()
        }
        lock.lock()
        for (id, k) in waiting { if let v = cache[k] { out[id] = v } }
        lock.unlock()
        return out
    }

    /// Queues photos for checking in the background, without waiting.
    public func enqueue(_ requests: [Request]) { check(requests, timeout: 0) }

    // MARK: Work queue

    private final class Job {
        let key: String
        let request: Request
        var urgent: Bool
        var waiters: [() -> Void] = []
        init(key: String, request: Request, urgent: Bool) { self.key = key; self.request = request; self.urgent = urgent }
    }

    private func submit(_ r: Request, key: String, urgent: Bool, onDone: @escaping () -> Void) {
        lock.lock()
        if let j = jobs[key] {
            j.waiters.append(onDone)
            if urgent && !j.urgent, let i = queued.firstIndex(where: { $0 === j }) {
                queued.remove(at: i); j.urgent = true
                queued.insert(j, at: queued.firstIndex { !$0.urgent } ?? queued.count)
            }
            lock.unlock(); return
        }
        // Background work doesn't hammer a photo that just failed; a request asking for it does retry.
        if !urgent, let f = failedAt[key], Date().timeIntervalSince(f) < retryAfter { lock.unlock(); onDone(); return }
        if !urgent && queued.count >= Self.maxQueued { lock.unlock(); onDone(); return }
        let j = Job(key: key, request: r, urgent: urgent)
        j.waiters.append(onDone)
        jobs[key] = j
        if urgent { queued.insert(j, at: queued.firstIndex { !$0.urgent } ?? queued.count) } else { queued.append(j) }
        lock.unlock()
        pump()
    }

    private func pump() {
        lock.lock()
        var start: [Job] = []
        while running < Self.maxRunning, !queued.isEmpty { start.append(queued.removeFirst()); running += 1 }
        lock.unlock()
        for j in start {
            DispatchQueue.global(qos: j.urgent ? .userInitiated : .utility).async { [self] in
                let result = analyze(j.request)
                lock.lock()
                if let (key, v) = result { store(v, for: key); failedAt[j.key] = nil } else { failedAt[j.key] = Date() }
                jobs[j.key] = nil
                running -= 1
                let waiters = j.waiters
                lock.unlock()
                waiters.forEach { $0() }
                pump()
            }
        }
    }

    // MARK: Analysis

    /// Looks at one photo. Returns the cache key (for the bytes actually read) and the verdict, or
    /// nil when it couldn't be finished (no model, error, timeout). nil is never cached.
    func analyze(_ r: Request) -> (String, PhotoVerdict)? {
        guard let engine = engineKey, let classifier = usableClassifier, let recognizer else { return nil }
        let size = r.data?.count ?? ((try? FileManager.default.attributesOfItem(atPath: r.url.path)[.size] as? Int) ?? nil)
        if let size, size > maxFileBytes {
            return ("\(engine)|\(r.id)|too-large-\(size)", PhotoVerdict(problem: .tooLarge))
        }
        guard let data = r.data ?? (try? Data(contentsOf: r.url, options: .mappedIfSafe)) else { return nil }
        let key = "\(engine)|\(r.id)|\(Self.digest(data))"
        let image: CGImage
        switch Self.workingImage(data) {
        case .success(let i): image = i
        case .failure(let p): return (key, PhotoVerdict(problem: p.problem))
        }

        // The model looks at the picture while the text is read and judged.
        let seen = Pending<Result<ModelVerdict, Error>>()
        classifier.classify(image) { seen.set($0) }
        let sensitive = Pending<Bool?>()
        let scaOn = nudity?.isEnabled == true
        if scaOn, let nudity { nudity.analyze(image) { sensitive.set($0) } }

        var v = PhotoVerdict()
        guard let text = try? recognizer.recognize(image) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            v.hasText = true
            v.textFound = Set(Detectors.scan(trimmed).map(\.category))
            if textFilter.usableClassifier != nil {
                let item = ContentFilter.Item(id: -r.id - 1, text: trimmed)   // negative: never a message id
                guard let tv = textFilter.classify([item], timeout: modelTimeout)[item.id] else { return nil }
                v.textVerdict = tv
            }
        }
        switch seen.wait(timeout: modelTimeout) {
        case .success(let m)?: v.seen = m
        case .failure(let e)? where e is ImageCheckRefused: v.problem = .refused
        default: return nil
        }
        if scaOn, let flagged = sensitive.wait(timeout: 15) ?? nil { v.flaggedSensitive = flagged }
        return (key, v)
    }

    struct LoadFailure: Error { let problem: PhotoVerdict.Problem }

    /// Decodes the first frame (GIF, HEIC sequence, sticker…), upright, at most `workingSize` on its longest side.
    static func workingImage(_ data: Data) -> Result<CGImage, LoadFailure> {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return .failure(LoadFailure(problem: .unreadable)) }
        guard let type = CGImageSourceGetType(src) as String?, let ut = UTType(type), ut.conforms(to: .image),
              CGImageSourceGetCount(src) > 0 else { return .failure(LoadFailure(problem: .unsupported)) }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 0, h = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { return .failure(LoadFailure(problem: .unreadable)) }
        guard w * h <= maxPixels else { return .failure(LoadFailure(problem: .tooLarge)) }
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: workingSize] as CFDictionary) else { return .failure(LoadFailure(problem: .unreadable)) }
        return .success(img)
    }

    /// True for files Check mode can share at all (photos). Everything else is withheld.
    public static func isPhoto(mimeType: String?, url: URL?) -> Bool {
        if let m = mimeType, let t = UTType(mimeType: m) { return t.conforms(to: .image) }
        if let ext = url?.pathExtension, let t = UTType(filenameExtension: ext) { return t.conforms(to: .image) }
        return false
    }

    // MARK: Decisions

    /// Applies a chat's settings to a photo's verdict (nil = not checked yet).
    public static func decide(_ v: PhotoVerdict?, policy: FilterPolicy, isPhoto: Bool, allowedByUser: Bool = false) -> PhotoOutcome {
        if allowedByUser { var o = PhotoOutcome.shown; o.allowedByUser = true; return o }
        switch policy.attachments {
        case .allow: return .shown
        case .withhold: return PhotoOutcome()
        case .check: break
        }
        guard isPhoto else { return PhotoOutcome(notAPhoto: true) }
        guard let v else { return PhotoOutcome(notCleared: true, pending: true) }
        var o = PhotoOutcome(withheld: false)
        if let p = v.problem { return PhotoOutcome(notCleared: true, problem: p) }
        func judge(_ c: FilterCategory, _ l: ConcernLevel, threshold: Int) {
            if l == .unsure { o.withheld = true; o.notCleared = true }
            else if l.rank >= threshold { o.withheld = true; o.reasons.insert(c) }
        }
        // "Is this an ID / a card / a document?" isn't a matter of degree the way a topic is: the model
        // rates a plain passport photo "clear", not "strong". So photo categories withhold at Balanced
        // even when How strict is Relaxed; Strict makes them stricter.
        let photoThreshold = min(policy.strictness.threshold.rank, ConcernLevel.clear.rank)
        for c in FilterCategory.photoCategories where policy.action(c) == .withhold {
            judge(c, c == .nudity && v.flaggedSensitive ? .strong : v.seen.level(c), threshold: photoThreshold)
        }
        let threshold = policy.strictness.threshold.rank
        for c in FilterCategory.modelCategories where policy.action(c) == .withhold {
            var l = v.seen.level(c)
            if v.hasText {
                // Text in the photo that the text model couldn't judge can't be cleared.
                let t = v.textVerdict?.level(c) ?? .unsure
                if t == .unsure || (l != .unsure && t.rank > l.rank) { l = t }
            }
            judge(c, l, threshold: threshold)
        }
        // A pattern in the photo can't be masked out of the picture, so anything not allowed withholds it.
        // Swearing is left alone: it's not private, and masking it is only cosmetic.
        for c in v.textFound where c != .profanity && policy.action(c) != .allow {
            o.withheld = true; o.reasons.insert(c)
        }
        return o
    }
}

/// A value delivered once from another thread, waited for with a timeout.
final class Pending<T>: @unchecked Sendable {
    private let cond = NSCondition()
    private var value: T?
    func set(_ v: T) { cond.lock(); if value == nil { value = v }; cond.broadcast(); cond.unlock() }
    func wait(timeout: TimeInterval) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        cond.lock(); defer { cond.unlock() }
        while value == nil { if !cond.wait(until: deadline) { break } }
        return value
    }
}
