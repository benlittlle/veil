import Foundation

// The assistant's settings tools. They exist only while "Assistant can change settings" is Ask me or
// Apply directly; while it's Off they aren't listed and calling one gives the same answer as a tool
// that doesn't exist. `Gate.call` has already refused everything while the settings are locked or paused.

extension Gate {
    static let settingsTools: Set<String> = ["get_settings", "get_chat_settings", "change_chat_settings",
                                             "change_app_settings", "check_settings_request"]
    /// At most this many settings requests wait for the user at once.
    static let maxPendingSettings = 3
    /// In Apply directly, at most this many changes per window apply on their own; past that they ask,
    /// so a manipulated assistant can't flip many settings in a burst without the user seeing it.
    static let directChangeLimit = (count: 10, seconds: 600.0)

    /// Records a direct change if the burst limit allows it.
    func takeDirectChangeSlot(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _directChangeTimes.removeAll { now.timeIntervalSince($0) > Self.directChangeLimit.seconds }
        guard _directChangeTimes.count < Self.directChangeLimit.count else { return false }
        _directChangeTimes.append(now)
        return true
    }

    /// The mode the assistant sees: Off whenever the signed settings can't be trusted.
    public var agentSettingsMode: AgentSettingsMode {
        switch permissions.integrity {
        case .ok, .firstRun: return permissions.state.agentSettings
        case .tampered: return .off
        }
    }

    public var settingsRequests: [SettingsRequest] { expireSettingsRequests(); lock.lock(); defer { lock.unlock() }; return _settingsRequests }

    func settingsTool(_ tool: String, _ args: JSON, _ state: PermissionState, _ convs: [Conversation], _ client: String) throws -> (ToolResult, String, Conversation?) {
        let mode = state.agentSettings
        guard mode != .off else { throw Denied(message: "Unknown tool \(tool).") }
        expireSettingsRequests()

        func chat() throws -> Conversation {
            // Hidden chats aren't in `convs`, so they get exactly the answer a made-up id gets.
            guard let id = args["chat_id"]?.string, let c = convs.first(where: { $0.id == id }) else {
                throw Denied(message: "No chat with that chat_id. Use list_chats to see available chats.")
            }
            return c
        }
        func invalid(_ e: SettingsError, _ c: Conversation? = nil) -> Denied {
            Denied(message: e.message, chat: c, summary: "Refused a settings change: \(e.message)")
        }

        switch tool {
        case "get_settings":
            return (.json(appSettingsJSON(state, mode)), "Looked at app settings", nil)

        case "get_chat_settings":
            let c = try chat()
            return (.json(chatSettingsJSON(c, state)), "Looked at this chat's settings", c)

        case "change_chat_settings":
            let c = try chat()
            let change: ChatSettingsChange
            do { change = try SettingsArgs.chat(args) } catch let e as SettingsError { throw invalid(e, c) }
            let before = state.chats[c.id] ?? .none
            do { _ = try change.applied(to: before, in: state) } catch let e as SettingsError { throw invalid(e, c) }
            let lines = change.lines(from: before, in: state)
            guard !lines.isEmpty else { return unchanged(c) }
            let codes = change.allowsCodes(from: before, in: state)
            let caution = codes ? "This lets \(c.displayName)'s PINs and verification codes through. An assistant that can read one-time codes can sign in to your accounts." : nil
            let target = SettingsRequest.Target.chat(id: c.id, name: c.displayName, change: change)
            let direct = mode == .direct && !codes && takeDirectChangeSlot()
            if direct {
                let r = SettingsRequest(id: newSettingsID(), target: target, lines: lines, created: Date(), client: client, caution: nil, status: .approved)
                do { try applyChat(c.id, change, markReviewed: false) }
                catch let e as SettingsError { throw invalid(e, c) }
                catch { throw Denied(message: "Veil couldn't save that change. Nothing was changed.", chat: c, summary: "Couldn't save a settings change: \(error.localizedDescription)") }
                return applied(r, c)
            }
            return try ask(SettingsRequest(id: newSettingsID(), target: target, lines: lines, created: Date(), client: client,
                                           caution: caution, status: .pending), c, codes: codes && mode == .direct,
                           overLimit: mode == .direct && !codes)

        case "change_app_settings":
            let change: AppSettingsChange
            do { change = try SettingsArgs.app(args) } catch let e as SettingsError { throw invalid(e) }
            let lines = change.lines(state: state, prefs: preferences)
            guard !lines.isEmpty else { return unchanged(nil) }
            let r = SettingsRequest(id: newSettingsID(), target: .app(change), lines: lines, created: Date(), client: client,
                                    caution: nil, status: mode == .direct ? .approved : .pending)
            let direct = mode == .direct && takeDirectChangeSlot()
            if direct {
                do { try applyApp(change) }
                catch { throw Denied(message: "Veil couldn't save that change. Nothing was changed.", summary: "Couldn't save a settings change: \(error.localizedDescription)") }
                return applied(r, nil)
            }
            var pending = r; pending.status = .pending
            return try ask(pending, nil, codes: false, overLimit: mode == .direct)

        case "check_settings_request":
            guard let id = args["request_id"]?.string, let r = settingsRequests.first(where: { $0.id == id }) else {
                throw Denied(message: "No settings request with that id. Finished requests are forgotten after an hour.")
            }
            var out: [String: JSON] = ["request_id": .string(r.id), "status": .string(r.status.label),
                                       "changes": .array(r.lines.map { .string($0.short) })]
            if case .cancelled(let why) = r.status { out["reason"] = .string(why) }
            let c = r.chatID.flatMap { id in convs.first { $0.id == id } }
            return (.json(.object(out)), "Checked a settings request: \(r.status.label)", c)

        default:
            throw Denied(message: "Unknown tool \(tool).")
        }
    }

    private func unchanged(_ c: Conversation?) -> (ToolResult, String, Conversation?) {
        (.json(["status": "unchanged", "note": "Those settings already have these values. Nothing was changed."]),
         "Asked for a settings change that was already in place", c)
    }

    private func applied(_ r: SettingsRequest, _ c: Conversation?) -> (ToolResult, String, Conversation?) {
        onSettingsChange?()
        onSettingsApplied?(r)
        var out: [String: JSON] = ["status": "applied", "changes": .array(r.lines.map { .string($0.short) }),
                                   "note": "Applied right away. The user is notified of every change."]
        if let c { out["chat_id"] = .string(c.id) }
        return (.json(.object(out)), "Changed settings\(c.map { " for \($0.displayName)" } ?? ""): \(r.shortSummary)", c)
    }

    private func ask(_ r: SettingsRequest, _ c: Conversation?, codes: Bool, overLimit: Bool = false) throws -> (ToolResult, String, Conversation?) {
        lock.lock()
        guard _settingsRequests.filter({ $0.status == .pending }).count < Self.maxPendingSettings else {
            lock.unlock()
            throw Denied(message: "The user already has \(Self.maxPendingSettings) settings changes waiting for approval. Wait for those first.", chat: c,
                         summary: "Refused a settings change: \(Self.maxPendingSettings) already waiting")
        }
        _settingsRequests.insert(r, at: 0)
        lock.unlock()
        onOutboxChange?()
        onSettingsRequested?(r)
        let minutes = Int(settingsRequestLifetime / 60)
        let l = Self.directChangeLimit
        let why = codes ? "Allowing PINs & verification codes always needs the user's approval. "
            : overLimit ? "More than \(l.count) changes in \(Int(l.seconds / 60)) minutes need the user's approval. " : ""
        return (.json(["status": "pending", "request_id": .string(r.id), "changes": .array(r.lines.map { .string($0.short) }),
                       "note": .string(why + "The user will see this in Veil and decide. Use check_settings_request to follow up; it expires after \(minutes) minutes.")]),
                "Asked to change settings\(c.map { " for \($0.displayName)" } ?? ""): \(r.shortSummary) (waiting for approval)", c)
    }

    // MARK: - Applying (one atomic write each; the same code paths as the app)

    func applyChat(_ chatID: String, _ change: ChatSettingsChange, markReviewed: Bool) throws {
        try updateChat(chatID, markReviewed: markReviewed) { a, s in a = try change.applied(to: a, in: s) }
    }

    func applyApp(_ c: AppSettingsChange) throws {
        if c.paused != nil || c.autoSendAllowed != nil || c.autoSendLimit != nil {
            try permissions.update { s in
                if let p = c.paused { s.paused = p }
                if let a = c.autoSendAllowed { s.autoSendStopped = !a }
                if let l = c.autoSendLimit { s.setAutoSendLimit(l) }
            }
        }
        preferences.update(assistantName: c.assistantName, newMessagePings: c.newMessagePings, pingWhenIReply: c.pingWhenIReply)
        if c.paused == true { didPause() }
    }

    // MARK: - The user's decision (menu bar app only)

    /// The user clicked Allow. Claimed once, then everything is checked again against the live settings.
    public func approveSettings(_ id: String) {
        expireSettingsRequests()
        guard let r = updateSettings(id, from: .pending, to: .applying) else { return }
        let fail = { (why: String) in
            _ = self.updateSettings(id, from: .applying, to: .cancelled(why))
            self.log.append(self.entry(client: "You", tool: "approve_settings", chatID: r.chatID, chatName: r.chatName, .failed,
                                       "Couldn't apply a settings change: \(why)"))
        }
        let state = permissions.state
        guard agentSettingsMode != .off else { return fail("settings changes are turned off") }
        guard !state.paused else { return fail("Veil is paused") }
        do {
            switch r.target {
            case .chat(let chatID, _, let change):
                guard let convs = try? conversations(), convs.contains(where: { $0.id == chatID }), !state.access(chatID).hidden else {
                    return fail("that chat isn't available any more")
                }
                try applyChat(chatID, change, markReviewed: true)
            case .app(let change):
                try applyApp(change)
            }
        } catch let e as SettingsError {
            return fail(e.message)
        } catch {
            return fail(error.localizedDescription)
        }
        _ = updateSettings(id, from: .applying, to: .approved)
        log.append(entry(client: "You", tool: "approve_settings", chatID: r.chatID, chatName: r.chatName, .allowed,
                         "Approved a settings change\(r.chatName.map { " for \($0)" } ?? ""): \(r.shortSummary)"))
        onSettingsChange?()
    }

    public func declineSettings(_ id: String) {
        guard let r = updateSettings(id, from: .pending, to: .declined) else { return }
        log.append(entry(client: "You", tool: "decline_settings", chatID: r.chatID, chatName: r.chatName, .allowed,
                         "Declined a settings change\(r.chatName.map { " for \($0)" } ?? ""): \(r.shortSummary)"))
    }

    /// Marks requests nobody answered in time as expired, and forgets finished ones after an hour.
    public func expireSettingsRequests(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-settingsRequestLifetime)
        lock.lock()
        var expired: [SettingsRequest] = []
        for i in _settingsRequests.indices where _settingsRequests[i].status == .pending && _settingsRequests[i].created <= cutoff {
            _settingsRequests[i].status = .expired
            expired.append(_settingsRequests[i])
        }
        let before = _settingsRequests.count
        _settingsRequests.removeAll { $0.status != .pending && $0.status != .applying && $0.created < now.addingTimeInterval(-3600) }
        let changed = !expired.isEmpty || before != _settingsRequests.count
        lock.unlock()
        for r in expired {
            log.append(entry(client: "Veil", tool: "expire_settings", chatID: r.chatID, chatName: r.chatName, .denied,
                             "A settings change expired without an answer: \(r.shortSummary)"))
        }
        if changed { onOutboxChange?() }
    }

    func cancelSettingsRequests(reason: String) {
        lock.lock()
        var changed = false
        for i in _settingsRequests.indices where _settingsRequests[i].status == .pending {
            _settingsRequests[i].status = .cancelled(reason); changed = true
        }
        lock.unlock()
        if changed { onOutboxChange?() }
    }

    private func updateSettings(_ id: String, from: SettingsRequest.Status, to status: SettingsRequest.Status) -> SettingsRequest? {
        lock.lock()
        guard let i = _settingsRequests.firstIndex(where: { $0.id == id }), _settingsRequests[i].status == from else { lock.unlock(); return nil }
        _settingsRequests[i].status = status
        let r = _settingsRequests[i]
        lock.unlock()
        onOutboxChange?()
        return r
    }

    private func newSettingsID() -> String { "c-" + UUID().uuidString.prefix(8).lowercased() }

    // MARK: - What the assistant can read

    func appSettingsJSON(_ state: PermissionState, _ mode: AgentSettingsMode) -> JSON {
        let l = state.effectiveAutoSendLimit
        return [
            "settings_changes": .string(mode == .direct ? "direct" : "ask"),
            "paused": .bool(state.paused),
            "assistant_name": .string(preferences.assistantName),
            "new_message_pings": .bool(preferences.newMessagePings),
            "ping_when_i_reply": .bool(preferences.pingWhenIReply),
            "auto_send": .bool(!state.autoSendStopped),
            "auto_send_limit": ["count": JSON(l.count), "minutes": JSON(l.minutes)],
            "note": .string((mode == .direct ? "Changes apply right away and the user is notified. "
                                             : "Each change waits for the user's approval in Veil. ")
                            + "Allowing PINs & verification codes always needs approval. Pausing blocks every tool, these included, so only the user can unpause."),
        ]
    }

    func chatSettingsJSON(_ c: Conversation, _ state: PermissionState) -> JSON {
        let a = state.chats[c.id] ?? .none
        let p = a.filterPolicy ?? state.effectiveFilterProfile
        var o: [String: JSON] = ["chat_id": .string(c.id), "name": .string(c.displayName), "type": c.isGroup ? "group" : "direct"]
        for s in ChatSettingsChange.Switch.allCases { o[s.rawValue] = .bool(a[keyPath: s.keyPath]) }
        o["auto_send"] = .bool(a.send && a.autoSend)
        o["auto_send_active"] = .bool(state.access(c.id).autoSend)
        o["filter"] = [
            "on": .bool(a.filtered),
            "uses_default_settings": .bool(a.filterPolicy == nil),
            "strictness": .string(p.strictness.rawValue),
            "photos": .string(p.attachments.rawValue),
            "categories": .object(Dictionary(uniqueKeysWithValues: FilterCategory.allCases.map { ($0.mcpName, JSON.string(p.action($0).rawValue)) })),
        ]
        return .object(o)
    }
}
