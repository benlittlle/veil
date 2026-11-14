import Foundation
import CryptoKit

// The content filter. For chats the user set to "Filtered", every piece of message content passes
// through here, on this Mac, before the gate returns it. Two layers, and either one can act:
//
//   1. Deterministic detectors (Detectors.swift) find card numbers, codes, bank details, IDs,
//      secrets and swearing. Matches are masked in place, or the message is withheld.
//   2. A `ContentClassifier` (Apple's on-device model by default) judges topics a pattern
//      can't: politics, health, sexual content, arguments, money worries.
//
// It fails closed: no classifier, an error, a timeout, a refusal or an unsure answer all mean
// the message is withheld, unless every judgement category is set to Allow.
//
// Only verdicts are cached (per message ROWID + a content digest + engine id + prompt version),
// never text, and only in memory.

/// How strongly a message touches a judgement category.
public enum ConcernLevel: String, Codable, Sendable, CaseIterable {
    case none, mild, clear, strong
    /// The model couldn't tell. Always withholds.
    case unsure

    var rank: Int {
        switch self { case .none: return 0; case .mild: return 1; case .clear: return 2; case .strong: return 3; case .unsure: return 4 }
    }
}

/// A classifier's judgement of one message.
public struct ModelVerdict: Equatable, Sendable {
    public var levels: [FilterCategory: ConcernLevel]
    public init(_ levels: [FilterCategory: ConcernLevel]) { self.levels = levels }
    /// Missing categories count as unsure.
    public func level(_ c: FilterCategory) -> ConcernLevel { levels[c] ?? .unsure }
    public static let clear = ModelVerdict(Dictionary(uniqueKeysWithValues: FilterCategory.modelCategories.map { ($0, .none) }))
}

public struct ClassifierItem: Sendable, Equatable {
    public let id: Int64
    public let text: String
    public init(id: Int64, text: String) { self.id = id; self.text = text }
}

public enum ClassifierStatus: Equatable, Sendable {
    case available
    /// Plain-language reason, shown to the user (never to the assistant).
    case unavailable(String)
    public var isAvailable: Bool { self == .available }
}

/// A judgement engine. Apple's on-device model is the built-in one; others (for example a
/// local open-weights model) can be added behind this protocol. Engines must run on this Mac.
public protocol ContentClassifier: AnyObject, Sendable {
    /// Changes whenever results could change (model, prompt, schema), so cached verdicts are redone.
    var engineID: String { get }
    /// Must be true. The filter refuses to use an engine that sends text anywhere.
    var isOnDevice: Bool { get }
    var status: ClassifierStatus { get }
    /// Judges a batch. Missing ids in the result are treated as unsure (withheld, not cached).
    /// May call back on any thread, at most once.
    func classify(_ items: [ClassifierItem], completion: @escaping @Sendable (Result<[Int64: ModelVerdict], Error>) -> Void)
}

/// What the filter decided for one message.
public struct FilterOutcome: Equatable, Sendable {
    /// The text to return (masked), or nil if there was none. Ignored when `withheld`.
    public var text: String?
    /// Attachment names, masked, by attachment id.
    public var attachmentNames: [Int64: String] = [:]
    public var withheld = false
    /// Number of masked spans across text and names.
    public var maskedSpans = 0
    /// Why (the user-only). Never sent to the assistant or written to the log.
    public var reasons: Set<FilterCategory> = []
    /// Withheld because the model couldn't clear it (unavailable, error, timeout, unsure).
    public var notCleared = false
    /// The user let this message through.
    public var allowedByUser = false

    public var masked: Bool { !withheld && maskedSpans > 0 }
    public static let withheldMarker = "[withheld]"
    public static let removedMarker = "[removed]"
}

/// Counts for the access log. Never content or reasons.
public struct FilterTally: Equatable, Sendable {
    public var masked = 0
    public var withheld = 0
    public init() {}
    public mutating func add(_ o: FilterOutcome?) {
        guard let o else { return }
        if o.withheld { withheld += 1 } else if o.maskedSpans > 0 { masked += 1 }
    }
    public var summary: String { "\(masked) masked, \(withheld) withheld" }
}

public final class ContentFilter: @unchecked Sendable {
    public struct Item: Sendable {
        public let id: Int64
        public let text: String?
        public let attachments: [(id: Int64, name: String?)]
        public init(id: Int64, text: String?, attachments: [(id: Int64, name: String?)] = []) {
            self.id = id; self.text = text; self.attachments = attachments
        }
        /// What the model judges: the text plus file names.
        var modelText: String {
            ([text ?? ""] + attachments.compactMap(\.name)).filter { !$0.isEmpty }.joined(separator: "\n")
        }
    }

    public let classifier: ContentClassifier?
    /// Bump when the prompt or schema changes, so old verdicts are redone.
    public static let promptVersion = 1
    /// Messages per model call. Smaller batches judge more accurately; larger ones are faster.
    public static let defaultBatchSize = 8
    public var batchSize = ContentFilter.defaultBatchSize
    static let maxInFlight = 2
    /// Longest text per model call. Longer messages are judged in overlapping pieces.
    public static let maxModelChars = 1200
    /// How long a request waits for uncached messages before withholding them.
    public var onDemandTimeout: TimeInterval = 4

    private let lock = NSLock()
    private var cache: [String: ModelVerdict] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 50_000

    public init(classifier: ContentClassifier?) { self.classifier = classifier }

    /// The classifier, only if it's on-device and ready. Anything else means "can't clear".
    var usableClassifier: ContentClassifier? {
        guard let c = classifier, c.isOnDevice, c.status.isAvailable else { return nil }
        return c
    }

    /// The user-facing status of the judgement layer.
    public var modelStatus: ClassifierStatus {
        guard let c = classifier else { return .unavailable("No on-device model is set up on this Mac.") }
        guard c.isOnDevice else { return .unavailable("The configured model isn't on-device, so it's never used.") }
        return c.status
    }

    // MARK: Cache (verdicts only)

    func cacheKey(_ item: Item, engine: String) -> String {
        let digest = SHA256.hash(data: Data(item.modelText.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(engine)|p\(Self.promptVersion)|\(item.id)|\(digest)"
    }

    public func cachedVerdict(_ item: Item) -> ModelVerdict? {
        guard let c = classifier else { return nil }
        let k = cacheKey(item, engine: c.engineID)
        lock.lock(); defer { lock.unlock() }
        return cache[k]
    }

    private func store(_ v: ModelVerdict, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = v
        if cacheOrder.count > cacheLimit {
            let drop = cacheOrder.prefix(cacheOrder.count - cacheLimit)
            for k in drop { cache[k] = nil }
            cacheOrder.removeFirst(drop.count)
        }
    }

    public var cachedCount: Int { lock.lock(); defer { lock.unlock() }; return cache.count }
    public func clearCache() { lock.lock(); cache = [:]; cacheOrder = []; lock.unlock() }

    // MARK: Classification

    /// Classifies the uncached items, waiting at most `timeout` seconds overall. Returns the
    /// verdicts that arrived in time. Late answers are still cached for next time.
    @discardableResult
    func classify(_ items: [Item], timeout: TimeInterval) -> [Int64: ModelVerdict] {
        guard let c = usableClassifier else { return [:] }
        let engine = c.engineID
        var out: [Int64: ModelVerdict] = [:]
        var misses: [(Item, String)] = []
        lock.lock()
        for i in items where !i.modelText.isEmpty {
            let k = cacheKey(i, engine: engine)
            if let v = cache[k] { out[i.id] = v } else { misses.append((i, k)) }
        }
        lock.unlock()
        guard !misses.isEmpty, timeout > 0 else { return out }

        let deadline = Date().addingTimeInterval(timeout)
        // Long messages are split into overlapping pieces; each piece is judged and the message
        // gets the most concerning answer. It only counts as judged once every piece is answered.
        var pieces: [(id: Int64, text: String, owner: Int)] = []
        var pieceIDs: [[Int64]] = []
        var nextPiece: Int64 = 0
        for (n, (item, _)) in misses.enumerated() {
            var ids: [Int64] = []
            for text in Self.chunksForModel(item.modelText) {
                nextPiece += 1
                pieces.append((nextPiece, text, n)); ids.append(nextPiece)
            }
            pieceIDs.append(ids)
        }
        let collector = Collector(owners: misses.map { ($0.0.id, $0.1) }, pieces: pieceIDs)
        let batches = stride(from: 0, to: pieces.count, by: batchSize).map { Array(pieces[$0..<min($0 + batchSize, pieces.count)]) }
        // At most two model calls in flight; nothing new starts after the deadline. A classifier
        // that never calls back only costs this request its deadline.
        let flight = Flight(max: Self.maxInFlight)
        let keep: @Sendable (ModelVerdict, String) -> Void = { [weak self] v, k in self?.store(v, for: k) }
        DispatchQueue.global(qos: .userInitiated).async {
            defer { flight.doneLaunching() }
            for batch in batches {
                guard flight.acquire(before: deadline) else { return }
                let asked = Set(batch.map(\.id))
                c.classify(batch.map { ClassifierItem(id: $0.id, text: $0.text) }) { result in
                    if case .success(let verdicts) = result {
                        // Ignore ids we didn't ask about; cache each message once all its pieces are in.
                        for (key, v) in collector.add(verdicts.filter { asked.contains($0.key) }) { keep(v, key) }
                    }
                    flight.release()
                }
            }
        }
        flight.waitForAll(before: deadline)
        for (id, v) in collector.complete() { out[id] = v }
        return out
    }

    /// Up to `maxModelChars` per piece, overlapping by 200 characters so nothing falls between pieces.
    static func chunksForModel(_ s: String) -> [String] {
        guard s.count > maxModelChars else { return [s] }
        var out: [String] = []
        var start = s.startIndex
        while start < s.endIndex {
            let end = s.index(start, offsetBy: maxModelChars, limitedBy: s.endIndex) ?? s.endIndex
            out.append(String(s[start..<end]))
            if end == s.endIndex { break }
            start = s.index(end, offsetBy: -200)
        }
        return out
    }

    /// Gathers piece verdicts and combines them per message (the most concerning level wins).
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private let owners: [(id: Int64, key: String)]
        private let pieces: [[Int64]]
        private var answers: [Int64: ModelVerdict] = [:]
        private var done: [Int64: ModelVerdict] = [:]
        init(owners: [(Int64, String)], pieces: [[Int64]]) { self.owners = owners.map { (id: $0.0, key: $0.1) }; self.pieces = pieces }

        /// Returns (cache key, verdict) for each message that just became complete.
        func add(_ v: [Int64: ModelVerdict]) -> [(String, ModelVerdict)] {
            lock.lock(); defer { lock.unlock() }
            answers.merge(v) { a, _ in a }
            var newly: [(String, ModelVerdict)] = []
            for (n, ids) in pieces.enumerated() where done[owners[n].id] == nil {
                let got = ids.compactMap { answers[$0] }
                guard got.count == ids.count else { continue }
                var combined: [FilterCategory: ConcernLevel] = [:]
                for c in FilterCategory.modelCategories {
                    combined[c] = got.map { $0.level(c) }.max { $0.rank < $1.rank } ?? .unsure
                }
                let verdict = ModelVerdict(combined)
                done[owners[n].id] = verdict
                newly.append((owners[n].key, verdict))
            }
            return newly
        }
        func complete() -> [Int64: ModelVerdict] { lock.lock(); defer { lock.unlock() }; return done }
    }

    // MARK: Evaluation

    /// Decides what to return for each item. `timeout` bounds waiting for the model on uncached messages.
    public func evaluate(_ items: [Item], policy: FilterPolicy, allowed: Set<Int64> = [], timeout: TimeInterval? = nil) -> [Int64: FilterOutcome] {
        var verdicts: [Int64: ModelVerdict] = [:]
        if policy.needsModel {
            let toJudge = items.filter { !allowed.contains($0.id) }
            verdicts = classify(toJudge, timeout: timeout ?? onDemandTimeout)
        }
        var out: [Int64: FilterOutcome] = [:]
        for i in items { out[i.id] = decide(i, policy: policy, verdict: verdicts[i.id], allowedByUser: allowed.contains(i.id)) }
        return out
    }

    /// Applies a policy to one message, given the model's verdict (nil = none available).
    public func decide(_ item: Item, policy: FilterPolicy, verdict: ModelVerdict?, allowedByUser: Bool = false) -> FilterOutcome {
        var o = FilterOutcome(text: item.text)
        for a in item.attachments { if let n = a.name { o.attachmentNames[a.id] = n } }
        if allowedByUser { o.allowedByUser = true; return o }

        // Layer 1: detectors.
        if let t = item.text {
            let (masked, spans, hits) = Self.mask(t, policy: policy)
            o.text = masked; o.maskedSpans += spans; o.reasons.formUnion(hits.masked)
            if !hits.withhold.isEmpty { o.reasons.formUnion(hits.withhold); o.withheld = true }
        }
        for a in item.attachments {
            guard let n = a.name else { continue }
            let (masked, spans, hits) = Self.mask(n, policy: policy)
            o.attachmentNames[a.id] = masked; o.maskedSpans += spans; o.reasons.formUnion(hits.masked)
            if !hits.withhold.isEmpty { o.reasons.formUnion(hits.withhold); o.withheld = true }
        }

        // Layer 2: the model, for judgement categories that aren't Allow.
        if policy.needsModel, !item.modelText.isEmpty {
            if let v = verdict {
                for c in FilterCategory.modelCategories where policy.action(c) == .withhold {
                    let l = v.level(c)
                    if l == .unsure { o.withheld = true; o.notCleared = true }
                    else if l.rank >= policy.strictness.threshold.rank { o.withheld = true; o.reasons.insert(c) }
                }
            } else {
                o.withheld = true; o.notCleared = true
            }
        }
        if o.withheld { o.text = FilterOutcome.withheldMarker; o.attachmentNames = [:] }
        return o
    }

    struct Hits { var masked: Set<FilterCategory> = []; var withhold: Set<FilterCategory> = [] }

    /// Replaces each detected span whose category is set to Mask. Overlapping spans are merged.
    static func mask(_ text: String, policy: FilterPolicy) -> (String, Int, Hits) {
        var hits = Hits()
        var spans: [(Range<String.Index>, Bool)] = []   // (range, isSwear)
        for d in Detectors.scan(text) {
            switch policy.action(d.category) {
            case .allow: continue
            case .withhold: hits.withhold.insert(d.category)
            case .mask: hits.masked.insert(d.category); spans.append((d.range, d.category == .profanity))
            }
        }
        guard !spans.isEmpty else { return (text, 0, hits) }
        spans.sort { $0.0.lowerBound < $1.0.lowerBound }
        var merged: [(Range<String.Index>, Bool)] = []
        for s in spans {
            if let last = merged.last, s.0.lowerBound < last.0.upperBound {
                merged[merged.count - 1] = (last.0.lowerBound..<max(last.0.upperBound, s.0.upperBound), last.1 && s.1)
            } else { merged.append(s) }
        }
        var out = "", cursor = text.startIndex
        for (r, swear) in merged {
            out += text[cursor..<r.lowerBound]
            out += swear ? Detectors.maskSwear(text[r]) : FilterOutcome.removedMarker
            cursor = r.upperBound
        }
        out += text[cursor...]
        return (out, merged.count, hits)
    }

    /// A chat's name through the detectors. A name can't be withheld the way a message is, so every
    /// pattern category that isn't Allow is masked.
    public static func maskName(_ name: String, policy: FilterPolicy) -> String {
        var p = policy
        for c in FilterCategory.detectorCategories where p.action(c) == .withhold { p.set(c, .mask) }
        return mask(name, policy: p).0
    }

    /// Counts model calls in flight, without the balance rules of DispatchGroup/DispatchSemaphore
    /// (a classifier may never call back).
    private final class Flight: @unchecked Sendable {
        private let cond = NSCondition()
        private let max: Int
        private var running = 0
        private var launching = true
        init(max: Int) { self.max = max }
        func acquire(before deadline: Date) -> Bool {
            cond.lock(); defer { cond.unlock() }
            guard Date() < deadline else { return false }
            while running >= max { if !cond.wait(until: deadline) { return false } }
            running += 1; return true
        }
        func release() { cond.lock(); running -= 1; cond.broadcast(); cond.unlock() }
        func doneLaunching() { cond.lock(); launching = false; cond.broadcast(); cond.unlock() }
        func waitForAll(before deadline: Date) {
            cond.lock(); defer { cond.unlock() }
            while launching || running > 0 { if !cond.wait(until: deadline) { return } }
        }
    }

}
