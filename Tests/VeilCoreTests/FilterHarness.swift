import Foundation
@testable import VeilCore

/// A stand-in for the on-device model. Judges by keywords, and can be told to fail in every way
/// the real one can. The default test run never touches the real model.
final class FakeClassifier: ContentClassifier, @unchecked Sendable {
    /// `held`: answers normally, but only once `release()` is called.
    enum Behavior { case normal, error, refuse, hang, held, unsure, dropAnswers, unavailable }

    private let lock = NSLock()
    private var _behavior: Behavior = .normal
    private var _calls: [[ClassifierItem]] = []
    private var held: [(items: [ClassifierItem], completion: @Sendable (Result<[Int64: ModelVerdict], Error>) -> Void)] = []
    var behavior: Behavior { get { lock.lock(); defer { lock.unlock() }; return _behavior } set { lock.lock(); _behavior = newValue; lock.unlock() } }
    var calls: [[ClassifierItem]] { lock.lock(); defer { lock.unlock() }; return _calls }
    var engineID = "fake/1"
    var isOnDevice = true

    /// keyword (lowercased) → what it signals
    var rules: [String: (FilterCategory, ConcernLevel)] = [
        "senator": (.politics, .strong), "election": (.politics, .clear),
        "biopsy": (.health, .clear), "chemo": (.health, .strong),
        "overdraft": (.moneyWorries, .mild), "nude": (.sexual, .strong),
        "idiot": (.conflict, .clear), "hmmmaybe": (.health, .unsure),
    ]

    var status: ClassifierStatus {
        if case .unavailable = behavior { return .unavailable("Apple Intelligence is turned off.") }
        return .available
    }

    struct Failure: Error {}

    func classify(_ items: [ClassifierItem], completion: @escaping @Sendable (Result<[Int64: ModelVerdict], Error>) -> Void) {
        lock.lock()
        _calls.append(items)
        let b = _behavior
        if case .held = b { held.append((items, completion)) }
        lock.unlock()
        switch b {
        case .error, .unavailable: completion(.failure(Failure()))
        case .refuse: completion(.failure(Failure()))     // e.g. a guardrail violation or refusal
        case .hang: return                                // never answers
        case .held: return                                // answers when released
        case .unsure:
            completion(.success(Dictionary(uniqueKeysWithValues: items.map { ($0.id, ModelVerdict(Dictionary(uniqueKeysWithValues: FilterCategory.modelCategories.map { ($0, ConcernLevel.unsure) }))) })))
        case .dropAnswers: completion(.success([:]))
        case .normal: completion(.success(judge(items)))
        }
    }

    /// Answers everything held back so far, and answers normally from now on.
    func release() {
        lock.lock(); let waiting = held; held = []; _behavior = .normal; lock.unlock()
        for w in waiting { w.completion(.success(judge(w.items))) }
    }

    func judge(_ items: [ClassifierItem]) -> [Int64: ModelVerdict] {
        var out: [Int64: ModelVerdict] = [:]
        for i in items {
            var v = ModelVerdict.clear
            let t = i.text.lowercased()
            for (k, (c, l)) in rules where t.contains(k) {
                if l.rank > v.level(c).rank || l == .unsure { v.levels[c] = l }
            }
            out[i.id] = v
        }
        return out
    }
}

/// Planted sensitive messages, added to Alex's chat (row 3) on top of the standard fixture.
/// Each `secrets` value must never reach the assistant once the chat is filtered.
final class FilterHarness {
    let h: Harness
    let fake = FakeClassifier()
    let db: SQLiteDB
    private var nextID: Int64 = 20_000
    var ids: [String: Int64] = [:]

    /// Values that must never come out of a filtered chat (with the standard profile).
    static let secrets = ["4111", "845221", "31926819", "20-00-00", "GB82", "JG103759A", "078-05-1120", "Tr0ub4dor",
                          "sk-proj", "fucking", "senator", "biopsy", "chemo", "hmmmaybe", "2468"]
    /// Ordinary text that must come through untouched.
    static let ordinary = "Meet at 7pm on 12/05/2024, call +44 7700 900123 or (555) 010-0001, it costs £1,234.56 for 3 nights"

    init(access: [String: ChatAccess]? = nil, classifier: Bool = true, imageClassifier: ImageClassifier? = nil,
         recognizer: TextRecognizer? = VisionTextRecognizer(), nudity: NudityDetector? = nil) throws {
        let a = access ?? Harness.defaultAccess.merging([ID.alex: ChatAccess(read: true, waiting: true, draft: true, filtered: true)]) { $1 }
        h = try Harness(access: a, classifier: classifier ? fake : nil, imageClassifier: imageClassifier, recognizer: recognizer, nudity: nudity)
        // Requests wait as long as the fake model takes, so a busy machine can't turn a clean message into
        // a withheld one. The fail-closed tests set their own short timeouts.
        h.gate.filter.onDemandTimeout = 30
        db = try SQLiteDB(path: h.dir.appendingPathComponent("chat.db").path, readOnly: false)
        // Oldest first. Alex's existing messages are 20h and 6h old; these are newer.
        try add("card", "My card is 4111 1111 1111 1111 exp 12/27", hoursAgo: 5.0)
        let (_, codeGuid) = try add("code", "Your code is 845221", hoursAgo: 4.9)
        try add("bank", "Sort code 20-00-00 account 31926819 please", hoursAgo: 4.8)
        try add("iban", "IBAN GB82 WEST 1234 5698 7654 32 for the rent", hoursAgo: 4.7)
        try add("ni", "My NI number is JG103759A", hoursAgo: 4.6)
        try add("ssn", "SSN 078-05-1120 on the form", hoursAgo: 4.5)
        try add("password", "wifi password: Tr0ub4dor&3 enjoy", hoursAgo: 4.4)
        try add("key", "use sk-proj-abcDEF1234567890ghijKLMN for the API", hoursAgo: 4.3)
        try add("swear", "This is fucking great news", hoursAgo: 4.2)
        try add("politics", "I think the senator is a disgrace", hoursAgo: 4.1)
        try add("ordinary", Self.ordinary, hoursAgo: 4.0)
        try add("reply", "Thanks, got it", hoursAgo: 3.9, replyTo: codeGuid)
        try add("unsure", "hmmmaybe things are fine", hoursAgo: 3.8)
        try add("pin", "PIN for the door is 2468", hoursAgo: 3.7)
        try add("health", "My doctor says the biopsy came back, chemo starts Monday", hoursAgo: 1.0)   // newest: Alex is waiting
    }

    @discardableResult
    func add(_ name: String, _ text: String, hoursAgo: Double, chatRow: Int64 = 3, fromMe: Bool = false, replyTo: String? = nil) throws -> (Int64, String) {
        nextID += 1
        let guid = "PLANT-\(nextID)"
        let date = appleTimestamp(Date().addingTimeInterval(-hoursAgo * 3600))
        try db.query("INSERT INTO message (ROWID, guid, text, handle_id, date, is_from_me, thread_originator_guid, associated_message_type, item_type) VALUES (?,?,?,?,?,?,?,0,0)",
                     [.int(nextID), .text(guid), .text(text), .int(fromMe ? 0 : 2), .int(date), .int(fromMe ? 1 : 0), replyTo.map { .text($0) } ?? .null])
        try db.query("INSERT INTO chat_message_join VALUES (?, ?, ?)", [.int(chatRow), .int(nextID), .int(date)])
        ids[name] = nextID
        return (nextID, guid)
    }

    func call(_ tool: String, _ args: JSON = [:]) -> Harness.Out { h.call(tool, args) }
    var gate: Gate { h.gate }

    func messages(_ chat: String = ID.alex) -> [JSON] {
        call("read_chat", ["chat_id": .string(chat), "limit": 200]).json["messages"]?.array ?? []
    }
    func text(of name: String, _ chat: String = ID.alex) -> String? {
        messages(chat).first { $0["id"]?.int.map(Int64.init) == ids[name] }?["text"]?.string
    }

    func noSecrets(_ s: String, _ what: String, except: Set<String> = []) -> [String] {
        Self.secrets.filter { !except.contains($0) && s.contains($0) }.map { "\(what) leaked \($0)" }
    }
}
