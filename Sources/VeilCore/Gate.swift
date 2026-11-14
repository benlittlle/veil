import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ToolResult: Sendable {
    public var content: [JSON]
    public var isError: Bool
    static func text(_ s: String, error: Bool = false) -> ToolResult { ToolResult(content: [["type": "text", "text": .string(s)]], isError: error) }
    static func json(_ j: JSON) -> ToolResult { .text(j.encoded(pretty: true)) }
}

/// The gate. Every MCP tool call goes through `call(tool:arguments:client:)`, which reads the
/// current permissions, filters at the source, and logs what happened. Permission changes are made
/// by the menu bar UI. The only MCP path to them is the settings tools in GateSettings.swift, which
/// exist only while the user has set "Assistant can change settings" to Ask me or Apply directly.
public final class Gate {
    public let permissions: PermissionStore
    public let log: AccessLog
    public let contacts: ContactResolver
    /// Content filter for chats the user set to "Filtered". Runs entirely on this Mac.
    public let filter: ContentFilter
    /// Photo checks for filtered chats whose photos are set to Check. Runs entirely on this Mac.
    public let photos: PhotoChecker
    private let sender: MessageSender
    private let openStore: () throws -> MessagesStore
    private var store: MessagesStore?
    let lock = NSLock()
    private var _drafts: [Draft] = []
    private var _sends: [SendRequest] = []
    /// Settings changes the assistant asked for (Ask me, or allowing codes). Guarded by `lock`.
    var _settingsRequests: [SettingsRequest] = []
    /// When recent "Apply directly" changes happened, for the burst limit.
    var _directChangeTimes: [Date] = []
    /// App preferences outside the signed file (assistant name, pings). The app passes its own.
    public let preferences: AppPreferences
    /// How long a settings request waits for the user before it expires.
    public var settingsRequestLifetime: TimeInterval = 600
    /// Called (on any thread) when the assistant asks for a settings change that needs the user's OK.
    public var onSettingsRequested: ((SettingsRequest) -> Void)?
    /// Called (on any thread) after the assistant changed settings without asking (Apply directly).
    public var onSettingsApplied: ((SettingsRequest) -> Void)?
    /// Called (on any thread) whenever the settings tools or an approval changed the settings.
    public var onSettingsChange: (() -> Void)?
    /// Messages sent without a prompt (chats with auto-send on). The user views this in the app.
    public let autoSends: AutoSendHistory
    private var limiter: AutoSendLimiter
    /// Called (on any thread) after each auto-send, for the optional notification.
    public var onAutoSend: ((AutoSendRecord) -> Void)?

    /// Called (on any thread) when drafts or send requests change.
    public var onOutboxChange: (() -> Void)?
    /// Called (on any thread) after time-limited shares ended and were locked, with their chat ids.
    public var onSharingEnded: (([String]) -> Void)?
    /// The time used for history windows and time limits. Tests move it forward.
    public var clock: () -> Date = { Date() }
    /// Called (on any thread) when the assistant asks to send something.
    public var onSendRequested: ((SendRequest) -> Void)?

    public static let meLabel = "me"

    public init(permissions: PermissionStore, log: AccessLog, contacts: ContactResolver,
                sender: MessageSender, autoSends: AutoSendHistory = AutoSendHistory(url: nil),
                classifier: ContentClassifier? = nil, imageClassifier: ImageClassifier? = nil,
                textRecognizer: TextRecognizer? = VisionTextRecognizer(), nudityDetector: NudityDetector? = nil,
                preferences: AppPreferences = MemoryPreferences(),
                openStore: @escaping () throws -> MessagesStore) {
        self.permissions = permissions; self.log = log; self.contacts = contacts
        self.preferences = preferences
        self.filter = ContentFilter(classifier: classifier)
        self.photos = PhotoChecker(classifier: imageClassifier, recognizer: textRecognizer, nudity: nudityDetector, textFilter: filter)
        self.sender = sender; self.openStore = openStore
        self.autoSends = autoSends
        limiter = AutoSendLimiter(history: autoSends.all)
    }

    struct Denied: Error {
        let message: String            // shown to the assistant
        var chat: Conversation? = nil
        var summary: String? = nil     // shown in the user's activity log (defaults to message)
    }

    // MARK: - Data access for the app UI (the user only)

    public func messagesStore() throws -> MessagesStore {
        lock.lock(); defer { lock.unlock() }
        if let store { return store }
        let s = try openStore(); store = s; return s
    }

    /// The chat list (names and participants, never message content). Rebuilt only after Messages
    /// changed the database or contact names changed; permissions are applied by each caller.
    public func conversations() throws -> [Conversation] {
        let store = try messagesStore()
        let token = try store.changeToken(), names = contacts.generation
        lock.lock()
        if let c = chatList, c.token == token, c.names == names { lock.unlock(); return c.convs }
        lock.unlock()
        let convs = try store.conversations(contacts: contacts)
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        // Read after the token, so a change in between only makes the next call rebuild.
        lock.lock(); chatList = (token, names, convs); lock.unlock()
        return convs
    }
    private var chatList: (token: Int64, names: Int, convs: [Conversation])?

    public var drafts: [Draft] { lock.lock(); defer { lock.unlock() }; return _drafts }
    public var sends: [SendRequest] { lock.lock(); defer { lock.unlock() }; return _sends }

    // MARK: - Permission changes (menu bar app only)

    public func setAccess(_ access: ChatAccess, for chatID: String) throws {
        try updateChat(chatID) { a, _ in a = access }
    }

    /// Flips some switches, leaving everything else (the time limit included) as it is. The app's toggles use
    /// this. `startFor` sets a time limit when this turns sharing on from nothing.
    public func setSwitches(_ values: [WritableKeyPath<ChatAccess, Bool>: Bool], for chatID: String, startFor: ShareDuration? = nil) throws {
        let now = clock()
        try updateChat(chatID, now: now) { a, _ in
            let was = a.hasAnySwitch
            // Send before auto-send, so turning both on in one go works.
            for (k, v) in values.sorted(by: { ($0.key == \ChatAccess.autoSend ? 1 : 0) < ($1.key == \ChatAccess.autoSend ? 1 : 0) }) { a.set(k, v) }
            if !was, a.hasAnySwitch, let d = startFor { a.expires = d.expiry(from: now) }
        }
    }

    /// How far back the assistant can read in this chat.
    public func setHistory(_ w: HistoryWindow, for chatID: String) throws {
        try updateChat(chatID) { a, _ in a.history = w }
    }

    /// When sharing ends on its own (nil: no time limit). Only while something is shared.
    public func setShareExpiry(_ end: Date?, for chatID: String) throws {
        try updateChat(chatID) { a, _ in if a.hasAnySwitch { a.expires = end } }
    }

    /// "End now": every switch off, the same as a time limit running out, but logged as the user's doing.
    public func endSharing(_ chatID: String) throws {
        let name = (try? conversations())?.first { $0.id == chatID }?.displayName ?? chatID
        try updateChat(chatID) { a, _ in a = a.allOffKeepingFilter }
        log.append(entry(client: "You", tool: "share_ended", chatID: chatID, chatName: name, .allowed, "You stopped sharing \(name)"))
    }

    /// Changes one chat atomically, then drops drafts and waiting sends it no longer allows. The app's
    /// switches and the assistant's settings tools both come through here. If `change` throws, nothing changes.
    /// A time limit that ran out is applied first, so a change never builds on a share that already ended.
    func updateChat(_ chatID: String, markReviewed: Bool = true, now: Date? = nil,
                    _ change: (inout ChatAccess, PermissionState) throws -> Void) throws {
        let now = now ?? clock()
        expireShares(now: now)
        try permissions.update { s in
            var before = s.chats[chatID] ?? .none
            if before.expired(at: now) { before = before.settled(after: before, now: now) }
            var a = before
            try change(&a, s)
            s.chats[chatID] = a.settled(after: before, now: now)
            if markReviewed { s.markReviewed([chatID]) }
        }
        purge(chatID: chatID)
    }

    /// Locks every share whose time limit has run out: every switch off (auto-send included), drafts and
    /// waiting sends purged the same way as turning switches off, and an Activity entry for each.
    /// Runs on every request, on the app's timer and at launch, so it holds even if Veil was asleep or closed.
    @discardableResult
    public func expireShares(now: Date? = nil) -> [String] {
        let now = now ?? clock()
        switch permissions.integrity { case .ok, .firstRun: break; case .tampered: return [] }
        guard !permissions.state.expiredChats(now: now).isEmpty else { return [] }
        var ended: [String] = []
        do { try permissions.update { s in ended = s.lockExpired(now: now) } } catch { return [] }
        guard !ended.isEmpty else { return [] }
        let names = Dictionary(((try? conversations()) ?? []).map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        for id in ended {
            purge(chatID: id)
            let name = names[id] ?? id
            log.append(entry(client: "Veil", tool: "share_ended", chatID: id, chatName: name, .allowed, "Sharing with \(name) ended, as scheduled"))
        }
        onSharingEnded?(ended)
        return ended
    }

    public func setPaused(_ paused: Bool) throws {
        try permissions.update { $0.paused = paused }
        if paused { didPause() }
    }

    func didPause() {
        cancelWaitingSends(where: { _ in true }, reason: "The user paused Veil")
        cancelSettingsRequests(reason: "Veil was paused")
    }

    /// Off, Ask me or Apply directly. The app's Settings is the only caller; no MCP tool reaches this.
    public func setAgentSettings(_ mode: AgentSettingsMode) throws {
        try permissions.update { $0.agentSettings = mode }
        if mode == .off { cancelSettingsRequests(reason: "the user turned off settings changes") }
    }

    /// Kill switch for every chat's auto-send. Per-chat choices are kept for when it's turned back on.
    public func setAutoSendStopped(_ stopped: Bool) throws {
        try permissions.update { $0.autoSendStopped = stopped }
    }

    public func setAutoSendLimit(_ limit: AutoSendLimit) throws {
        try permissions.update { $0.setAutoSendLimit(limit) }
    }

    public func markReviewed(_ ids: [String]) throws {
        try permissions.update { $0.markReviewed(ids) }
    }

    // MARK: - Content filter settings (menu bar app only; no MCP path reaches these)

    /// Off (false) or Filtered (true) for one chat. Keeps the chat's other switches.
    public func setFiltered(_ on: Bool, for chatID: String) throws {
        try permissions.update { var a = $0.chats[chatID] ?? .none; a.filtered = on; $0.chats[chatID] = a; $0.markReviewed([chatID]) }
    }

    /// The default profile used by filtered chats without their own settings.
    public func setFilterProfile(_ p: FilterPolicy) throws {
        try permissions.update { $0.filterProfile = p == .standard ? nil : p }
    }

    /// A chat's own filter settings; nil goes back to the default profile.
    public func setChatFilterPolicy(_ p: FilterPolicy?, for chatID: String) throws {
        try permissions.update { var a = $0.chats[chatID] ?? .none; a.filterPolicy = p; $0.chats[chatID] = a }
    }

    /// The user's review: let one message through unfiltered (or filter it again).
    public func setFilterAllowed(_ allowed: Bool, message id: Int64, in chatID: String) throws {
        try permissions.update {
            var a = $0.chats[chatID] ?? .none
            var ids = Set(a.filterAllowedMessages)
            if allowed { ids.insert(id) } else { ids.remove(id) }
            a.filterAllowedMessages = Array(ids.sorted().suffix(1000))
            $0.chats[chatID] = a
        }
    }

    /// The user's review: let one photo through unchecked (or check it again).
    public func setPhotoAllowed(_ allowed: Bool, attachment id: Int64, in chatID: String) throws {
        try permissions.update {
            var a = $0.chats[chatID] ?? .none
            var ids = Set(a.filterAllowedPhotos)
            if allowed { ids.insert(id) } else { ids.remove(id) }
            a.filterAllowedPhotos = Array(ids.sorted().suffix(1000))
            $0.chats[chatID] = a
        }
    }

    /// The user's review: "always allow this category in this chat". Gives the chat its own settings if needed.
    public func alwaysAllow(_ category: FilterCategory, in chatID: String) throws {
        try permissions.update {
            var a = $0.chats[chatID] ?? .none
            var p = a.filterPolicy ?? $0.effectiveFilterProfile
            p.set(category, .allow)
            a.filterPolicy = p
            $0.chats[chatID] = a
        }
    }

    /// One filtered (or the user-allowed) message, for the user's review screen. Never reachable from MCP.
    public struct FilterReviewItem: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let date: Date
        public let from: String
        public let original: String
        /// What the assistant gets: masked text, or "[withheld]".
        public let shown: String
        public let withheld: Bool
        public let reasons: [FilterCategory]
        /// Withheld because the model couldn't clear it.
        public let notCleared: Bool
        public let allowedByUser: Bool
    }

    /// Recent messages in a chat that the filter changed, with why. For the user's eyes only (the app UI).
    public func filterReview(chatID: String, limit: Int = 150, timeout: TimeInterval = 20) throws -> [FilterReviewItem] {
        let state = permissions.state
        guard let policy = state.filterPolicy(for: chatID) else { return [] }
        let store = try messagesStore()
        let convs = try conversations()
        guard let c = convs.first(where: { $0.id == chatID }) else { return [] }
        let now = clock()
        let scope = attachScope(convs, state, now)
        // What the assistant could be shown: the chat's history window applies here too.
        let msgs = try store.messages(inChats: c.chatRowIDs, limit: limit, notBefore: state.historyCutoff(chatID, now: now))
        let items = msgs.map { filterItem($0, store, scope) }
        let allowed = Set(state.chats[chatID]?.filterAllowedMessages ?? [])
        // Judge as if nothing were allowed, so the user sees why an allowed message would be filtered.
        let outcomes = filter.evaluate(items, policy: policy, allowed: [], timeout: timeout)
        return msgs.compactMap { m in
            guard let o = outcomes[m.id], o.withheld || o.maskedSpans > 0 else { return nil }
            return FilterReviewItem(id: m.id, date: m.date, from: senderLabel(m), original: m.text ?? "(no text)",
                                    shown: o.withheld ? FilterOutcome.withheldMarker : (o.text ?? ""),
                                    withheld: o.withheld, reasons: o.reasons.sorted(), notCleared: o.notCleared,
                                    allowedByUser: allowed.contains(m.id))
        }
    }

    private let warmLock = NSLock()
    private var warming = false
    /// The background pass's own connection, kept between passes.
    private var warmStore: MessagesStore?
    /// What the last background pass saw, and whether every item in it got a verdict.
    private var lastWarm: (token: Int64, state: PermissionState, engines: String, complete: Bool)?

    /// One photo the filter held back (or the user let through), for the user's review screen. Never reachable from MCP.
    public struct PhotoReviewItem: Identifiable, Equatable, Sendable {
        /// The attachment id.
        public let id: Int64
        public let messageID: Int64
        public let date: Date
        public let from: String
        public let name: String?
        public let outcome: PhotoOutcome
        public var withheld: Bool { outcome.withheld }
        public var reasons: [FilterCategory] { outcome.reasons.sorted() }
        public var allowedByUser: Bool { outcome.allowedByUser }
    }

    /// Recent photos in a chat that Check mode held back, with why. For the user's eyes only (the app UI).
    public func photoReview(chatID: String, limit: Int = 40, timeout: TimeInterval = 30) throws -> [PhotoReviewItem] {
        let state = permissions.state
        guard let policy = state.filterPolicy(for: chatID), policy.attachments == .check else { return [] }
        let store = try messagesStore()
        let convs = try conversations().filter { !state.access($0.id).hidden }
        guard let c = convs.first(where: { $0.id == chatID }) else { return [] }
        let allowed = Set(state.chats[chatID]?.filterAllowedPhotos ?? [])
        // Only photos that could be shared at all: one that's also in a chat without photos, or outside a
        // chat's history window, stays hidden anyway.
        let now = clock()
        let scope = attachScope(convs, state, now)
        let items = try store.attachments(inChats: c.chatRowIDs, limit: limit, notBefore: state.historyCutoff(chatID, now: now))
            .filter { a, _ in attachmentReachable(a.id, store, scope) && PhotoChecker.isPhoto(mimeType: a.mimeType, url: store.safeFileURL(for: a)) }
        let requests = items.compactMap { a, _ in store.safeFileURL(for: a).map { PhotoChecker.Request(id: a.id, url: $0) } }
        let verdicts = photos.check(requests, timeout: timeout, urgent: true)
        return items.compactMap { a, m in
            // Judged as if the user hadn't allowed it, so they see why it would be held back.
            var o = PhotoChecker.decide(verdicts[a.id], policy: policy, isPhoto: true)
            if allowed.contains(a.id) { o.allowedByUser = true } else if !o.withheld { return nil }
            return PhotoReviewItem(id: a.id, messageID: m.id, date: m.date, from: senderLabel(m), name: a.name, outcome: o)
        }
    }

    /// A small preview of a photo in a chat, for the user's review screen only.
    public func photoThumbnail(attachmentID: Int64, chatID: String, maxPixels: Int = 160) -> CGImage? {
        guard let store = try? messagesStore(), let c = try? conversations().first(where: { $0.id == chatID }),
              let rows = try? Set(store.chatRowIDs(forAttachment: attachmentID)), !rows.isDisjoint(with: c.chatRowIDs),
              let info = try? store.attachment(id: attachmentID), let url = store.safeFileURL(for: info),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary)
    }

    /// Checks recent messages and photos in filtered chats ahead of time, so requests find verdicts
    /// in the cache. Uses its own database connection. The app calls this in the background.
    public func warmFilterCache(perChat: Int = 200, photosPerChat: Int = 40) {
        let text = filter.usableClassifier != nil, pictures = photos.usableClassifier != nil
        guard text || pictures else { return }
        warmLock.lock()
        if warming { warmLock.unlock(); return }
        warming = true; warmLock.unlock()
        defer { warmLock.lock(); warming = false; warmLock.unlock() }

        let now = clock()
        var state = permissions.state
        state.lockExpired(now: now)
        guard !state.paused, permissions.integrity == .ok || permissions.integrity == .firstRun,
              state.chats.keys.contains(where: { state.filterPolicy(for: $0) != nil }) else { return }
        guard let store = try? warmStore ?? openStore() else { return }
        warmStore = store
        // Skip the pass when nothing it depends on changed since one that finished everything.
        let engines = "\(filter.usableClassifier?.engineID ?? "-")|\(photos.engineKey ?? "-")"
        let token = try? store.changeToken()
        if let token, let last = lastWarm, last.complete, last.token == token, last.state == state, last.engines == engines { return }
        guard let all = try? store.conversations(contacts: contacts) else { warmStore = nil; return }
        var complete = true
        defer { lastWarm = token.map { ($0, state, engines, complete) } }
        let convs = all.filter { !state.access($0.id, now: now).hidden }
        let scope = attachScope(convs, state, now)
        // Only what's inside each chat's history window: nothing older is ever shown, so it isn't checked.
        if pictures {
            // Photos first: they're slower, and the text pass below waits on the model.
            for c in convs {
                let a = state.access(c.id, now: now)
                guard a.attachments, let p = state.filterPolicy(for: c.id), p.attachments == .check else { continue }
                guard let items = try? store.attachments(inChats: c.chatRowIDs, limit: photosPerChat,
                                                         notBefore: state.historyCutoff(c.id, now: now)) else { complete = false; continue }
                let requests = items.compactMap { info, _ -> PhotoChecker.Request? in
                    guard attachmentReachable(info.id, store, scope), let url = store.safeFileURL(for: info),
                          PhotoChecker.isPhoto(mimeType: info.mimeType, url: url) else { return nil }
                    return PhotoChecker.Request(id: info.id, url: url)
                }
                if photos.check(requests, timeout: 0).count < requests.count { complete = false }
            }
        }
        for c in convs where text {
            let a = state.access(c.id, now: now)
            guard a.read || a.waiting || a.attachments, let p = state.filterPolicy(for: c.id), p.needsModel else { continue }
            guard let msgs = try? store.messages(inChats: c.chatRowIDs, limit: perChat,
                                                 notBefore: state.historyCutoff(c.id, now: now)) else { complete = false; continue }
            let skip = Set(a.filterAllowedMessages)
            let items = msgs.filter { !skip.contains($0.id) }.map { filterItem($0, store, scope) }
            let chunk = filter.batchSize * 2
            for start in stride(from: 0, to: items.count, by: chunk) {
                let part = Array(items[start..<min(start + chunk, items.count)])
                let judged = filter.classify(part, timeout: 60)
                if judged.count < part.filter({ !$0.modelText.isEmpty }).count { complete = false }
            }
        }
    }

    /// Drops anything derived from a chat that's no longer allowed.
    func purge(chatID: String) {
        let a = permissions.state.access(chatID)
        lock.lock()
        let before = _drafts.count
        if !a.draft { _drafts.removeAll { $0.chatID == chatID } }
        let changed = before != _drafts.count
        lock.unlock()
        if !a.send { cancelWaitingSends(where: { $0.chatID == chatID }, reason: "sending was turned off for this chat") }
        if changed { onOutboxChange?() }
    }

    func cancelWaitingSends(where match: (SendRequest) -> Bool, reason: String) {
        lock.lock()
        var changed = false
        for i in _sends.indices where _sends[i].status == .waiting && match(_sends[i]) {
            _sends[i].status = .cancelled(reason); changed = true
        }
        lock.unlock()
        if changed { onOutboxChange?() }
    }

    /// Start over after a tamper warning: everything off, nothing pending.
    public func resetAll() throws {
        try permissions.reset()
        lock.lock(); _drafts.removeAll(); lock.unlock()
        cancelWaitingSends(where: { _ in true }, reason: "permissions were reset")
        cancelSettingsRequests(reason: "permissions were reset")
    }

    /// Forget finished send requests (and their text) after an hour. Called periodically by the app.
    public func pruneFinishedSends(olderThan age: TimeInterval = 3600) {
        let cutoff = Date().addingTimeInterval(-age)
        lock.lock()
        let before = _sends.count
        _sends.removeAll { $0.status != .waiting && $0.status != .sending && $0.created < cutoff }
        let changed = before != _sends.count
        lock.unlock()
        if changed { onOutboxChange?() }
    }

    public func discardDraft(_ id: String) {
        lock.lock(); _drafts.removeAll { $0.id == id }; lock.unlock(); onOutboxChange?()
    }

    // MARK: - Send approval (menu bar app only)

    public func decline(_ id: String) {
        guard let req = updateSend(id, to: .declined) else { return }
        log.append(entry(client: "You", tool: "decline_send", chatID: req.chatID, chatName: req.chatName, .allowed, "Declined a message"))
    }

    /// The user clicked Send. Re-checks permission at the last moment, then hands off to Messages.
    public func approve(_ id: String) {
        // Claim the request atomically so a double click can't send it twice.
        guard let req = updateSend(id, to: .sending) else { return }
        expireShares()
        guard permissions.state.access(req.chatID, now: clock()).send, !permissions.state.paused else {
            _ = updateSend(id, from: .sending, to: .cancelled("sending was turned off for this chat")); return
        }
        do {
            guard let guid = try conversations().first(where: { $0.id == req.chatID })?.chatGUIDs.first else {
                throw Denied(message: "That chat no longer exists in Messages.")
            }
            try sender.send(req.text, toChatGUID: guid)
            _ = updateSend(id, from: .sending, to: .sent)
            log.append(entry(client: "You", tool: "approve_send", chatID: req.chatID, chatName: req.chatName, .allowed, "Approved and sent a message"))
        } catch {
            let msg = (error as? Denied)?.message ?? error.localizedDescription
            _ = updateSend(id, from: .sending, to: .failed(msg))
            log.append(entry(client: "You", tool: "approve_send", chatID: req.chatID, chatName: req.chatName, .failed, "Send failed: \(msg)"))
        }
    }

    private func updateSend(_ id: String, from: SendRequest.Status = .waiting, to status: SendRequest.Status) -> SendRequest? {
        lock.lock()
        guard let i = _sends.firstIndex(where: { $0.id == id }), _sends[i].status == from else { lock.unlock(); return nil }
        _sends[i].status = status
        let r = _sends[i]
        lock.unlock()
        onOutboxChange?()
        return r
    }

    // MARK: - MCP entry point

    public func call(tool: String, arguments: JSON, client: String) -> ToolResult {
        let args = arguments
        // Time limits are checked on every request, timer or not: ended shares are locked (and purged and
        // logged) first, and the snapshot below treats them as locked even if that write failed.
        let now = clock()
        expireShares(now: now)
        var state = permissions.state   // one consistent snapshot per request
        state.lockExpired(now: now)
        do {
            if case .tampered = permissions.integrity { throw Denied(message: "Veil is locked until the user reviews the permissions in the app.") }
            if state.paused { throw Denied(message: "The user has paused Veil. Nothing is available right now.") }
            let (result, summary, chat) = try dispatch(tool, args, state, client, now)
            log.append(entry(client: client, tool: tool, chatID: chat?.id, chatName: chat?.displayName, .allowed, summary))
            return result
        } catch let d as Denied {
            log.append(entry(client: client, tool: tool, chatID: d.chat?.id, chatName: d.chat?.displayName, .denied, d.summary ?? d.message))
            return .text(d.message, error: true)
        } catch {
            log.append(entry(client: client, tool: tool, chatID: nil, chatName: nil, .failed, "Error: \(error)"))
            return .text("Veil couldn't read Messages right now. Try again in a moment.", error: true)
        }
    }

    private func dispatch(_ tool: String, _ args: JSON, _ state: PermissionState, _ client: String, _ now: Date) throws -> (ToolResult, String, Conversation?) {
        let convs = try conversations().filter { !state.access($0.id).hidden }
        /// The chat's history window: nothing older than this is returned, as if it didn't exist.
        func cutoff(_ c: Conversation) -> Date? { state.historyCutoff(c.id, now: now) }
        func inWindow(_ d: Date, _ c: Conversation) -> Bool { cutoff(c).map { d >= $0 } ?? true }
        func historyNote(_ c: Conversation) -> String? { state.chats[c.id]?.history.assistantNote }

        func chat(_ need: KeyPath<ChatAccess, Bool>, _ what: String) throws -> Conversation {
            guard let id = args["chat_id"]?.string, let c = convs.first(where: { $0.id == id }) else {
                throw Denied(message: "No chat with that chat_id. Use list_chats to see available chats.")
            }
            guard state.access(c.id)[keyPath: need] else {
                throw Denied(message: "“\(c.displayName)” doesn't allow \(what). Only the user can change that, in the Veil app.",
                             chat: c, summary: "Blocked: \(what) is off for this chat")
            }
            return c
        }
        let store = try messagesStore()
        // Chat rows whose attachments may be shown. An attachment must be reachable only from these.
        // Filtered chats whose filter withholds photos & files are left out; in Check mode each photo must pass.
        let scope = attachScope(convs, state, now)
        /// Reply quotes, resolved only inside the same conversation and its history window.
        func quotes(_ msgs: [Message], _ c: Conversation) -> [String: Message] {
            var out: [String: Message] = [:]
            for g in Set(msgs.compactMap(\.replyToGUID)) {
                if let q = try? store.message(guid: g, inChats: c.chatRowIDs, notBefore: cutoff(c)), inWindow(q.date, c) { out[g] = q }
            }
            return out
        }
        /// Filter decisions for a filtered chat's messages (and their quotes), or nil when its filter is Off.
        func filtered(_ msgs: [Message], _ q: [String: Message], _ c: Conversation) -> [Int64: FilterOutcome]? {
            guard let p = state.filterPolicy(for: c.id) else { return nil }
            var seen = Set<Int64>()
            let items = (msgs + Array(q.values)).filter { seen.insert($0.id).inserted }.map { filterItem($0, store, scope) }
            return filter.evaluate(items, policy: p, allowed: Set(state.chats[c.id]?.filterAllowedMessages ?? []))
        }
        func render(_ m: Message, _ c: Conversation, _ q: [String: Message], _ f: [Int64: FilterOutcome]?) -> JSON {
            self.render(m, in: c, store: store, scope: scope, quotes: q, filtered: f)
        }
        func tally(_ msgs: [Message], _ f: [Int64: FilterOutcome]?) -> String {
            guard let f else { return "" }
            var t = FilterTally(); for m in msgs { t.add(f[m.id] ?? FilterOutcome(withheld: true)) }
            return ", " + t.summary
        }

        switch tool {
        case "list_chats":
            let q = args["query"]?.string?.lowercased() ?? ""
            let shown = convs.filter { c in
                q.isEmpty || c.displayName.lowercased().contains(q) || c.participants.contains { $0.handle.lowercased().contains(q) || ($0.name ?? "").lowercased().contains(q) }
            }
            // Only chats with read/waiting access reveal activity, and only inside their history window, so
            // only those are ordered by it. Everything else is sorted by name, so the order can't hint at
            // new messages, or at older ones outside a window.
            let visibleLast = { (c: Conversation) -> Date? in
                let a = state.access(c.id)
                guard a.read || a.waiting || a.activity, let d = c.lastActivity, inWindow(d, c) else { return nil }
                return d
            }
            let byName = { (x: Conversation, y: Conversation) in (x.displayName.lowercased(), x.id) < (y.displayName.lowercased(), y.id) }
            let ordered = shown.filter { visibleLast($0) != nil }.sorted { (visibleLast($0)!, $0.id) > (visibleLast($1)!, $1.id) }
                + shown.filter { visibleLast($0) == nil }.sorted(by: byName)
            let items: [JSON] = ordered.map { c in
                let a = state.access(c.id)
                var o: [String: JSON] = [
                    "chat_id": .string(c.id), "name": .string(c.displayName), "type": c.isGroup ? "group" : "direct",
                    "participants": .array(c.participants.map { ["name": JSON($0.name), "handle": .string($0.handle)] }),
                    "allowed": .array(Self.labels(a).map { .string($0) }),
                ]
                if let d = visibleLast(c) { o["last_activity"] = .string(iso(d)) }
                if !a.anyEnabled { o["note"] = "Locked. Only the name and number are visible until the user allows more." }
                else if let n = historyNote(c) { o["history"] = .string(n) }
                return .object(o)
            }
            let open = shown.filter { state.access($0.id).anyEnabled }.count
            return (.json(["chats": .array(items)]), "Listed \(shown.count) chats (\(open) with access)", nil)

        case "read_chat":
            let c = try chat(\.read, "reading")
            let limit = clamp(args["limit"]?.int, 40, 200)
            let page = try store.messages(inChats: c.chatRowIDs, beforeID: args["before_message_id"]?.int.map(Int64.init),
                                          limit: limit, notBefore: cutoff(c)).filter { inWindow($0.date, c) }
            let q = quotes(page, c)
            let f = filtered(page, q, c)
            let msgs = page.reversed().map { render($0, c, q, f) }
            var out: [String: JSON] = ["chat_id": .string(c.id), "name": .string(c.displayName), "messages": .array(msgs)]
            if page.count == limit, let oldest = page.last { out["older_messages_cursor"] = JSON(oldest.id) }
            if let n = historyNote(c) { out["history"] = .string(n) }
            if let p = state.filterPolicy(for: c.id) {
                out["note"] = .string(Self.filterNote + (p.attachments == .check && state.access(c.id).attachments ? " " + Self.photoCheckNote : ""))
            }
            return (.json(.object(out)), "Returned \(page.count) messages" + tally(page, f), c)

        case "search_messages":
            guard let q = args["query"]?.string?.trimmingCharacters(in: .whitespaces), q.count >= 2 else {
                throw Denied(message: "Give a query of at least 2 characters.")
            }
            var scope = convs.filter { state.access($0.id).read }
            if args["chat_id"]?.string != nil { scope = [try chat(\.read, "reading")] }
            let byRow = Dictionary(scope.flatMap { c in c.chatRowIDs.map { ($0, c) } }, uniquingKeysWith: { a, _ in a })
            // Each chat is searched only inside its own history window.
            let searchScopes = scope.map { MessagesStore.SearchScope(rows: $0.chatRowIDs, notBefore: cutoff($0)) }
            let limit = clamp(args["limit"]?.int, 20, 50)
            let anyFiltered = scope.contains { state.filterPolicy(for: $0.id) != nil }
            var t = FilterTally(), dropped = 0
            var results: [JSON] = []
            var hitChats = Set<String>()
            // Filtered chats can lose hits, so keep widening the raw search until there are `limit`
            // visible results or nothing more matches. That way the results depend only on what the
            // assistant could see, and hidden matches can't be counted by varying `limit`.
            var rawLimit = limit
            while true {
                t = FilterTally(); dropped = 0; results = []; hitChats = []
                let hits = try store.search(q, in: searchScopes, limit: rawLimit)
                    .filter { m in byRow[m.chatRowID].map { inWindow(m.date, $0) } ?? false }
                // Group hits per chat so each filtered chat is judged once, with its own settings.
                var perChat: [String: (Conversation, [Message])] = [:]
                for m in hits { if let c = byRow[m.chatRowID] { perChat[c.id, default: (c, [])].1.append(m) } }
                var quoteMap: [String: [String: Message]] = [:], filterMap: [String: [Int64: FilterOutcome]] = [:]
                for (id, (c, ms)) in perChat {
                    let qs = quotes(ms, c); quoteMap[id] = qs
                    if let f = filtered(ms, qs, c) { filterMap[id] = f }
                }
                for m in hits where results.count < limit {
                    guard let c = byRow[m.chatRowID] else { continue }
                    if let f = filterMap[c.id] {
                        // Match against what the assistant would see, so search can't probe masked or withheld text.
                        guard let o = f[m.id], !o.withheld, (o.text ?? "").localizedCaseInsensitiveContains(q) else { dropped += 1; continue }
                        t.add(o)
                    }
                    hitChats.insert(c.id)
                    results.append(["chat_id": .string(c.id), "chat_name": .string(c.displayName),
                                    "message": render(m, c, quoteMap[c.id] ?? [:], filterMap[c.id])])
                }
                guard anyFiltered, results.count < limit, hits.count == rawLimit, rawLimit < Self.maxRawSearch else { break }
                rawLimit = min(rawLimit * 4, Self.maxRawSearch)
            }
            let note = anyFiltered ? " (content filter: \(t.masked) masked, \(dropped) left out)" : ""
            return (.json(["query": .string(q), "searched_chats": JSON(scope.count), "results": .array(results)]),
                    "Searched \(scope.count) allowed chats for “\(q)”: \(results.count) results from \(hitChats.count) chats" + note, nil)

        case "waiting_on_reply":
            let days = clamp(args["days"]?.int, 14, 90)
            let lookBack = now.addingTimeInterval(-Double(days) * 86400)
            var rows: [(Date, JSON)] = []
            var t = FilterTally()
            for c in convs {
                let a = state.access(c.id)
                guard a.waiting || a.activity else { continue }
                // Timing comes from the metadata-only query; text is fetched only when Read is on.
                // Only messages inside the chat's history window count; with none, the chat isn't waiting.
                guard let last = try store.activity(inChats: c.chatRowIDs, limit: 1, notBefore: cutoff(c)).first,
                      inWindow(last.date, c), !last.isFromMe, last.date > lookBack else { continue }
                var o: [String: JSON] = ["chat_id": .string(c.id), "name": .string(c.displayName),
                                         "waiting_since": .string(iso(last.date)), "last_message_from": .string(senderLabel(last.senderHandle))]
                if a.read, let m = try store.latestMessage(inChats: c.chatRowIDs, notBefore: cutoff(c)), m.id == last.id {
                    if let f = filtered([m], [:], c) {
                        let out = f[m.id] ?? FilterOutcome(withheld: true)
                        t.add(out)
                        o["last_message"] = out.withheld ? .string(FilterOutcome.withheldMarker) : JSON(out.text.map { String($0.prefix(280)) })
                    } else {
                        o["last_message"] = JSON(m.text.map { String($0.prefix(280)) })
                    }
                }
                rows.append((last.date, .object(o)))
            }
            rows.sort { $0.0 < $1.0 }
            let note = t.masked + t.withheld > 0 ? " (content filter: \(t.summary))" : ""
            return (.json(["waiting": .array(rows.map(\.1))]), "Flagged \(rows.count) chats waiting on a reply" + note, nil)

        case "chat_activity":
            let c = try chat(\.seesActivity, "seeing activity")
            let limit = clamp(args["limit"]?.int, 50, 200)
            var since: Date?
            if let raw = args["since"]?.string {
                guard let d = parseSince(raw) else { throw Denied(message: "since must be an ISO 8601 time, like 2026-11-13T09:00:00Z.", chat: c) }
                since = d
            }
            let page = try store.activity(inChats: c.chatRowIDs, since: since, beforeID: args["before_message_id"]?.int.map(Int64.init),
                                          limit: limit, notBefore: cutoff(c)).filter { inWindow($0.date, c) }
            let sum = try store.activitySummary(inChats: c.chatRowIDs, notBefore: cutoff(c))
            let items: [JSON] = page.reversed().map { m in
                var o: [String: JSON] = ["id": JSON(m.id), "time": .string(iso(m.date)),
                                         "direction": .string(m.isFromMe ? "from_me" : "incoming")]
                if c.isGroup && !m.isFromMe { o["from"] = .string(senderLabel(m.senderHandle)) }
                return .object(o)
            }
            var out: [String: JSON] = [
                "chat_id": .string(c.id), "name": .string(c.displayName), "type": c.isGroup ? "group" : "direct",
                "last_incoming_at": JSON(sum.lastIncoming.map(iso)), "last_reply_at": JSON(sum.lastFromMe.map(iso)),
                // null when nobody else has written yet
                "replied_since_last_incoming": sum.lastIncoming == nil ? .null : .bool(!sum.awaitingReply),
                "messages": .array(items),
            ]
            if page.count == limit, let oldest = page.last { out["older_messages_cursor"] = JSON(oldest.id) }
            if !state.access(c.id).read { out["note"] = "Activity only: times and direction, no message content." }
            if let n = historyNote(c) { out["history"] = .string(n) }
            return (.json(.object(out)), "Returned activity for \(page.count) messages (no content)", c)

        case "list_attachments":
            let c = try chat(\.attachments, "photos & attachments")
            if let p = state.filterPolicy(for: c.id), !p.attachmentsShared {
                throw Denied(message: "“\(c.displayName)” doesn't share photos & attachments right now. Only the user can change that, in the Veil app.",
                             chat: c, summary: "Blocked: the content filter withholds photos & files in this chat")
            }
            let limit = clamp(args["limit"]?.int, 30, 100)
            let items = try store.attachments(inChats: c.chatRowIDs, beforeID: args["before_attachment_id"]?.int.map(Int64.init),
                                              limit: limit, notBefore: cutoff(c))
            // In a filtered chat, an attachment on a withheld message is left out, and names are masked.
            let f = filtered(items.map(\.1), [:], c)
            var heldBack = 0
            let list: [JSON] = items.filter { a, m in
                // Every chat it appears in must allow it, and each of those chats' window must include it.
                guard inWindow(m.date, c), attachmentReachable(a.id, store, scope) else { return false }
                if let f, f[m.id].map({ !$0.withheld }) != true { return false }
                // Check mode: only photos that already passed. The rest are checked in the background.
                guard photoCleared(a, store, scope) else { heldBack += 1; return false }
                return true
            }.map { a, m in
                let name = f.map { $0[m.id]?.attachmentNames[a.id] } ?? a.name
                return ["attachment_id": JSON(a.id), "time": .string(iso(m.date)), "from": .string(senderLabel(m)),
                        "type": JSON(a.mimeType), "name": JSON(name), "size_bytes": JSON(a.bytes)]
            }
            var out: [String: JSON] = ["chat_id": .string(c.id), "attachments": .array(list)]
            if let n = historyNote(c) { out["history"] = .string(n) }
            // Page on the raw list, so a page whose items are all hidden doesn't look like the end.
            if items.count == limit, let last = items.last { out["older_attachments_cursor"] = JSON(last.0.id) }
            let checking = state.filterPolicy(for: c.id)?.attachments == .check
            if checking { out["note"] = .string(Self.photoCheckNote) }
            return (.json(.object(out)), "Listed \(list.count) attachments" + (f != nil ? " (content filter on" + (checking ? ", \(heldBack) photos held back)" : ")") : ""), c)

        case "get_attachment":
            return try getAttachment(args, convs, state, store, now)

        case "draft_reply":
            let c = try chat(\.draft, "drafting replies")
            let text = try messageText(args)
            let d = Draft(id: "d-" + UUID().uuidString.prefix(8).lowercased(), chatID: c.id, chatName: c.displayName,
                          text: text, created: Date(), client: client)
            lock.lock()
            _drafts.insert(d, at: 0)
            // Keep at most 10 drafts per chat and 50 overall; the oldest go first.
            var perChat: [String: Int] = [:]
            _drafts = _drafts.filter { perChat[$0.chatID, default: 0] += 1; return perChat[$0.chatID]! <= 10 }.prefix(50).map { $0 }
            lock.unlock()
            onOutboxChange?()
            return (.json(["draft_id": .string(d.id), "status": "saved",
                           "note": "Saved as a draft in Veil for the user to review. Nothing was sent."]),
                    "Saved a draft (\(text.count) characters)", c)

        case "request_send":
            let c = try chat(\.send, "sending messages")
            let text = try messageText(args)
            guard !c.chatGUIDs.isEmpty else { throw Denied(message: "That chat can't be sent to.", chat: c) }
            // Auto-send: read the live settings (not the request's snapshot) right before deciding.
            var fallback: String?
            let live = permissions.state
            if live.access(c.id).autoSend, !live.paused {
                let keys = Set(args.objectKeys)
                if !keys.isSubset(of: ["chat_id", "text"]) {
                    fallback = "Auto-send covers plain text only, so the user needs to approve this one."
                } else if reserveAutoSendSlot(c.id, live.effectiveAutoSendLimit) {
                    return autoSend(text, to: c, client: client)
                } else {
                    let l = live.effectiveAutoSendLimit
                    fallback = "This chat reached its auto-send limit (\(l.count) per \(l.minutes) minutes), so the user needs to approve this one."
                }
            }
            let r = SendRequest(id: "s-" + UUID().uuidString.prefix(8).lowercased(), chatID: c.id, chatName: c.displayName,
                                text: text, created: Date(), client: client, status: .waiting)
            lock.lock()
            guard _sends.filter({ $0.status == .waiting }).count < 3 else {
                lock.unlock()
                throw Denied(message: "The user already has 3 messages waiting for approval. Wait for those first.", chat: c)
            }
            _sends.insert(r, at: 0)
            lock.unlock()
            onOutboxChange?()
            onSendRequested?(r)
            let note = "The user will see this message and decide whether to send it. Use check_send_status to follow up."
            return (.json(["request_id": .string(r.id), "status": .string(r.status.label),
                           "note": .string(fallback.map { $0 + " " + note } ?? note)]),
                    "Asked to send a message (\(text.count) characters), waiting for approval" + (fallback != nil ? " (auto-send limit or non-text)" : ""), c)

        case _ where Self.settingsTools.contains(tool):
            return try settingsTool(tool, args, state, convs, client)

        case "check_send_status":
            guard let id = args["request_id"]?.string, let r = sends.first(where: { $0.id == id }) else {
                throw Denied(message: "No send request with that id. Finished requests are forgotten after an hour.")
            }
            let c = convs.first { $0.id == r.chatID }
            return (.json(["request_id": .string(r.id), "status": .string(r.status.label)]), "Checked a send request: \(r.status.label)", c)

        default:
            throw Denied(message: "Unknown tool \(tool).")
        }
    }

    private func reserveAutoSendSlot(_ chat: String, _ limit: AutoSendLimit) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return limiter.reserve(chat, limit)
    }

    /// Sends without a prompt. Only reached when the chat has Send and Auto-send on, the kill
    /// switch is off, nothing is paused, and the chat is under its rate limit.
    private func autoSend(_ text: String, to c: Conversation, client: String) -> (ToolResult, String, Conversation?) {
        let r = SendRequest(id: "s-" + UUID().uuidString.prefix(8).lowercased(), chatID: c.id, chatName: c.displayName,
                            text: text, created: Date(), client: client, status: .sending)
        lock.lock(); _sends.insert(r, at: 0); lock.unlock()
        onOutboxChange?()
        var detail: String?
        do { try sender.send(text, toChatGUID: c.chatGUIDs[0]) } catch { detail = error.localizedDescription }
        let status: SendRequest.Status = detail == nil ? .sent : .failed("Messages couldn't send it.")
        _ = updateSend(r.id, from: .sending, to: status)
        let rec = AutoSendRecord(date: Date(), chatID: c.id, chatName: c.displayName, text: text, client: client,
                                 outcome: detail == nil ? .sent : .failed, detail: detail)
        autoSends.append(rec)
        onAutoSend?(rec)
        let note = detail == nil ? "Sent right away: the user allows auto-send for this chat." : "Auto-send failed. Nothing was sent."
        return (.json(["request_id": .string(r.id), "status": .string(status.label), "note": .string(note)]),
                detail == nil ? "Auto-sent a message (\(text.count) characters)" : "Auto-send failed", c)
    }

    private func getAttachment(_ args: JSON, _ convs: [Conversation], _ state: PermissionState, _ store: MessagesStore, _ now: Date) throws -> (ToolResult, String, Conversation?) {
        let notAvailable = Denied(message: Self.attachmentUnavailable)
        guard let id = args["attachment_id"]?.int.map(Int64.init), let info = try store.attachment(id: id) else { throw notAvailable }
        // Every chat this attachment appears in must allow attachments, and each one's history window must
        // include it. Fail closed otherwise, with the same answer as an attachment that doesn't exist.
        let scope = attachScope(convs, state, now)
        guard attachmentReachable(id, store, scope) else { throw notAvailable }
        let rows = Set(try store.chatRowIDs(forAttachment: id))
        let chat = convs.first { !rows.isDisjoint(with: $0.chatRowIDs) }

        // Filtered chats: the message carrying it must not be withheld; its name is masked.
        var name = info.name
        var inFilteredChat = false
        for c in convs where !rows.isDisjoint(with: c.chatRowIDs) {
            guard let p = state.filterPolicy(for: c.id) else { continue }
            inFilteredChat = true
            let msgs = try store.messages(forAttachment: id, inChats: c.chatRowIDs, notBefore: state.historyCutoff(c.id, now: now))
            guard !msgs.isEmpty else { throw notAvailable }
            let outcomes = filter.evaluate(msgs.map { filterItem($0, store, scope) }, policy: p,
                                           allowed: Set(state.chats[c.id]?.filterAllowedMessages ?? []))
            for m in msgs {
                guard let o = outcomes[m.id], !o.withheld else { throw notAvailable }
                if let n = name, !o.allowedByUser { name = ContentFilter.mask(n, policy: p).0 }
            }
        }

        var meta: [String: JSON] = ["attachment_id": JSON(id), "type": JSON(info.mimeType), "name": JSON(name), "size_bytes": JSON(info.bytes)]

        // Check mode: the photo must pass the on-device check, judged on the exact bytes returned below.
        let checks = scope.checkedChats(rows)
        if !checks.isEmpty {
            let held = { (why: String) in Denied(message: Self.attachmentUnavailable, chat: chat, summary: "Blocked: \(why) (content filter)") }
            let url = store.safeFileURL(for: info)
            guard PhotoChecker.isPhoto(mimeType: info.mimeType, url: url) else { throw held("not a photo, and only photos are checked") }
            let benAllowed = checks.allSatisfy { $0.allowedPhotos.contains(id) }
            guard let url, let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int else {
                throw held("the photo isn't on this Mac")
            }
            guard benAllowed || size <= photos.maxFileBytes, let data = try? Data(contentsOf: url) else { throw held("the photo couldn't be read or is too large") }
            if !benAllowed {
                let v = photos.check([PhotoChecker.Request(id: id, url: url, data: data)], timeout: photos.onDemandTimeout, urgent: true)[id]
                for c in checks {
                    let o = PhotoChecker.decide(v, policy: c.policy, isPhoto: true, allowedByUser: c.allowedPhotos.contains(id))
                    if o.pending { throw held("the photo hasn't been checked yet") }
                    if o.withheld { throw held("the photo didn't pass the check") }
                }
            }
            guard let jpeg = Self.jpeg(data) else { throw held("the photo couldn't be read") }
            return (ToolResult(content: [["type": "text", "text": .string(JSON.object(meta).encoded(pretty: true))],
                                         ["type": "image", "mimeType": "image/jpeg", "data": .string(jpeg.base64EncodedString())]], isError: false),
                    "Returned image attachment \(id) (checked on this Mac)", chat)
        }

        guard let url = store.safeFileURL(for: info), FileManager.default.isReadableFile(atPath: url.path) else {
            meta["note"] = "The file isn't downloaded to this Mac."
            return (.json(.object(meta)), "Attachment \(id): not on disk", chat)
        }
        let type = UTType(mimeType: info.mimeType ?? "") ?? UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .image) == true, let jpeg = Self.jpeg(url) {
            return (ToolResult(content: [["type": "text", "text": .string(JSON.object(meta).encoded(pretty: true))],
                                         ["type": "image", "mimeType": "image/jpeg", "data": .string(jpeg.base64EncodedString())]], isError: false),
                    "Returned image attachment \(id)", chat)
        }
        let realSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? Int.max
        // The text inside files isn't checked by the content filter (yet), so it's never returned from filtered chats.
        if inFilteredChat, type?.conforms(to: .text) == true || type?.conforms(to: .vCard) == true {
            meta["note"] = "File contents aren't shared from this chat."
            return (.json(.object(meta)), "Returned details for attachment \(id) (content filter on)", chat)
        }
        if type?.conforms(to: .text) == true || type?.conforms(to: .vCard) == true, realSize < 200_000,
           let s = try? String(contentsOf: url, encoding: .utf8) {
            meta["text"] = .string(s)
            return (.json(.object(meta)), "Returned text attachment \(id)", chat)
        }
        meta["note"] = "This file type can't be previewed."
        return (.json(.object(meta)), "Returned details for attachment \(id)", chat)
    }

    // MARK: - Rendering

    /// An attachment is reachable only if every chat it appears in allows attachments, and each of those
    /// chats' history window includes a message carrying it.
    private func attachmentReachable(_ id: Int64, _ store: MessagesStore, _ scope: AttachScope) -> Bool {
        guard let rows = try? Set(store.chatRowIDs(forAttachment: id)), !rows.isEmpty, rows.isSubset(of: scope.rows) else { return false }
        let windowed = rows.filter { scope.cutoffs[$0] != nil }
        guard !windowed.isEmpty else { return true }
        guard let latest = try? store.attachmentLatestDates(id) else { return false }
        return windowed.allSatisfy { r in latest[r].map { $0 >= scope.cutoffs[r]! } ?? false }
    }

    /// Check mode: the photo already passed for every Check-mode chat it appears in (or the user allowed it
    /// there). Never waits: anything not checked yet is queued in the background and left out for now.
    /// True when no Check-mode chat is involved.
    private func photoCleared(_ a: AttachmentInfo, _ store: MessagesStore, _ scope: AttachScope) -> Bool {
        guard !scope.checked.isEmpty, let rows = try? Set(store.chatRowIDs(forAttachment: a.id)) else { return true }
        let checks = scope.checkedChats(rows)
        guard !checks.isEmpty else { return true }
        if checks.allSatisfy({ $0.allowedPhotos.contains(a.id) }) { return true }
        let url = store.safeFileURL(for: a)
        guard PhotoChecker.isPhoto(mimeType: a.mimeType, url: url), let url else { return false }
        let r = PhotoChecker.Request(id: a.id, url: url)
        let v = photos.cached(r)
        if v == nil { photos.enqueue([r]) }
        return checks.allSatisfy { !PhotoChecker.decide(v, policy: $0.policy, isPhoto: true, allowedByUser: $0.allowedPhotos.contains(a.id)).withheld }
    }

    /// `filtered` is nil for chats whose filter is Off. When it's set, anything without a decision is withheld.
    private func render(_ m: Message, in c: Conversation, store: MessagesStore, scope: AttachScope,
                        quotes: [String: Message], filtered: [Int64: FilterOutcome]?) -> JSON {
        let decision = filtered.map { $0[m.id] ?? FilterOutcome(withheld: true) }
        if let d = decision, d.withheld {
            // Who and when only: the same metadata "See activity" shares. No text, quote or attachments.
            return ["id": JSON(m.id), "time": .string(iso(m.date)), "from": .string(senderLabel(m)), "text": .string(FilterOutcome.withheldMarker)]
        }
        var o: [String: JSON] = ["id": JSON(m.id), "time": .string(iso(m.date)), "from": .string(senderLabel(m)),
                                 "text": JSON(decision.map { $0.text } ?? m.text)]
        // Replies are only resolved inside the same conversation, so a quote can never pull text from elsewhere.
        if let g = m.replyToGUID, let orig = quotes[g] {
            var quoted = orig.text
            if let filtered {
                let q = filtered[orig.id] ?? FilterOutcome(withheld: true)
                quoted = q.withheld ? FilterOutcome.withheldMarker : q.text
            }
            o["reply_to"] = ["id": JSON(orig.id), "from": .string(senderLabel(orig)), "text": JSON(quoted.map { String($0.prefix(200)) })]
        }
        let visible = m.attachments.filter { attachmentReachable($0.id, store, scope) && photoCleared($0, store, scope) }
        if !visible.isEmpty {
            o["attachments"] = .array(visible.map { a in
                ["attachment_id": JSON(a.id), "type": JSON(a.mimeType),
                 "name": JSON(decision.map { $0.attachmentNames[a.id] } ?? a.name)]
            })
        }
        if visible.count < m.attachments.count { o["attachments_hidden"] = JSON(m.attachments.count - visible.count) }
        return .object(o)
    }

    /// How far search widens in filtered chats before giving up (raw matches).
    static let maxRawSearch = 5000

    /// Told to the assistant once per filtered chat. Never says what was filtered or why.
    static let filterNote = "The user's content filter is on for this chat. Some text shows as [removed] and some messages as [withheld]."
    /// Told to the assistant for chats whose photos are checked. Never says which photo or why.
    static let photoCheckNote = "Photos are shared only after an on-device check. Photos that haven't been checked yet or didn't pass are left out; new ones may appear in a minute or two."
    /// The same answer for every unavailable attachment, whatever the reason.
    static let attachmentUnavailable = "That attachment isn't available. It may not exist, or the user hasn't allowed photos & attachments for its chat."

    /// Chat rows whose attachments may be shown: Attachments on, and not withheld by a content filter.
    func attachmentRows(_ convs: [Conversation], _ state: PermissionState) -> Set<Int64> {
        Set(convs.filter { c in
            state.access(c.id).attachments && (state.filterPolicy(for: c.id)?.attachmentsShared ?? true)
        }.flatMap(\.chatRowIDs))
    }

    /// A filtered chat whose photos are checked.
    struct CheckedChat {
        let id: String
        let policy: FilterPolicy
        let allowedPhotos: Set<Int64>
    }

    /// Where attachments may come from, for one request.
    struct AttachScope {
        /// Rows whose attachments may be shown at all.
        let rows: Set<Int64>
        /// History windows: rows of chats that share only part of their history, with the oldest time shown.
        var cutoffs: [Int64: Date] = [:]
        /// Rows of filtered chats in Check mode, where each photo must pass the check.
        let checked: [Int64: CheckedChat]
        /// The Check-mode chats among some chat rows, once each.
        func checkedChats(_ rows: Set<Int64>) -> [CheckedChat] {
            var seen = Set<String>()
            return rows.sorted().compactMap { checked[$0] }.filter { seen.insert($0.id).inserted }
        }
    }

    func attachScope(_ convs: [Conversation], _ state: PermissionState, _ now: Date) -> AttachScope {
        var checked: [Int64: CheckedChat] = [:]
        var cutoffs: [Int64: Date] = [:]
        for c in convs { if let d = state.historyCutoff(c.id, now: now) { for r in c.chatRowIDs { cutoffs[r] = d } } }
        for c in convs where state.access(c.id).attachments {
            guard let p = state.filterPolicy(for: c.id), p.attachments == .check else { continue }
            let cc = CheckedChat(id: c.id, policy: p, allowedPhotos: Set(state.chats[c.id]?.filterAllowedPhotos ?? []))
            for r in c.chatRowIDs { checked[r] = cc }
        }
        return AttachScope(rows: attachmentRows(convs, state), cutoffs: cutoffs, checked: checked)
    }

    /// What the filter judges for a message: its text and the names of attachments the assistant could see.
    /// Background warming and requests build items the same way, so cached verdicts line up.
    func filterItem(_ m: Message, _ store: MessagesStore, _ scope: AttachScope) -> ContentFilter.Item {
        let visible = m.attachments.filter { attachmentReachable($0.id, store, scope) }
        return ContentFilter.Item(id: m.id, text: m.text, attachments: visible.map { (id: $0.id, name: $0.name) })
    }

    private func senderLabel(_ m: Message) -> String {
        m.isFromMe ? Self.meLabel : senderLabel(m.senderHandle)
    }

    private func senderLabel(_ handle: String?) -> String {
        guard let h = handle else { return "unknown" }
        return contacts.name(for: h) ?? h
    }

    private func messageText(_ args: JSON) throws -> String {
        guard let t = args["text"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else {
            throw Denied(message: "Include the message text.")
        }
        guard t.count <= 2000 else { throw Denied(message: "That message is too long (2000 characters max).") }
        // Keep the approval prompt honest: no hidden or direction-changing characters, no walls of blank lines.
        let hidden = t.unicodeScalars.contains { s in
            (s.properties.generalCategory == .control && s != "\n" && s != "\t") || s.properties.generalCategory == .format && s != "\u{200D}"
        }
        guard !hidden else { throw Denied(message: "That message contains invisible formatting characters. Use plain text.") }
        guard t.filter({ $0 == "\n" }).count <= 20, !t.contains("\n\n\n") else {
            throw Denied(message: "That message has too many line breaks.")
        }
        return t
    }

    static func labels(_ a: ChatAccess) -> [String] {
        guard !a.hidden else { return [] }
        return [(a.read, "read"), (a.waiting, "waiting_on_reply"), (a.draft, "draft_reply"),
                (a.send, "request_send"), (a.send && a.autoSend, "auto_send"), (a.attachments, "attachments"),
                (a.activity, "activity"), (a.filtered && a.anyEnabled, "content_filter")].filter(\.0).map(\.1)
    }

    func entry(client: String, tool: String, chatID: String?, chatName: String?, _ o: LogEntry.Outcome, _ s: String) -> LogEntry {
        LogEntry(date: Date(), client: client, tool: tool, chatID: chatID, chatName: chatName, outcome: o, summary: s)
    }

    static func jpeg(_ url: URL) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return jpeg(src)
    }

    static func jpeg(_ data: Data) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return jpeg(src)
    }

    private static func jpeg(_ src: CGImageSource) -> Data? {
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dst) ? out as Data : nil
    }
}

func clamp(_ v: Int?, _ def: Int, _ max: Int) -> Int { Swift.max(1, Swift.min(v ?? def, max)) }

private let isoFormatter: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.timeZone = .current; return f }()
func iso(_ d: Date) -> String { isoFormatter.string(from: d) }
