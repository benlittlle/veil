import SwiftUI
import AppKit
import VeilCore
import Contacts
import ServiceManagement
import UserNotifications
import os

/// App state for the UI. The gate itself lives in VeilCore; this just reflects it and
/// is the only place permissions are changed from.
@MainActor
final class AppModel: ObservableObject {
    enum Mode { case live, demo }

    let mode: Mode
    let gate: Gate
    let server: MCPServer
    /// New-message pings. Configured only from Settings; nothing in MCP can reach it.
    let webhook: WebhookNotifier
    /// Wakes the pings, the chat list and the filter when Messages writes to chat.db.
    private let watcher: DatabaseWatcher
    private var changePending = false
    private let webhookKey: KeychainString?
    let supportDir: URL
    let socketPath: String
    private var socket: UnixSocketServer?
    private var http: LocalHTTPServer?
    private let systemContacts: SystemContacts?

    @Published var diskAccessProblem: String?
    @Published var conversations: [Conversation] = []
    @Published var state = PermissionState() { didSet { updateGlyph(); scheduleShareEnd() } }
    private var shareTimer: Timer?, shareTimerTarget: Date?

    /// Wakes once, exactly when the next time-limited share ends, so the screen catches up without
    /// polling. Every request checks expiry on its own anyway; this is only for the UI and the purge.
    private func scheduleShareEnd() {
        let next = state.chats.values.compactMap(\.expires).filter { $0 > Date() }.min()
        guard next != shareTimerTarget else { return }
        shareTimer?.invalidate(); shareTimer = nil; shareTimerTarget = next
        guard let next else { return }
        let t = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.shareTimerTarget = nil; self?.gate.expireShares(); self?.reload() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        shareTimer = t
    }
    @Published var integrity: PermissionStore.Integrity = .ok
    @Published var log: [LogEntry] = []
    @Published var drafts: [Draft] = []
    @Published var sends: [SendRequest] = [] { didSet { updateGlyph() } }
    /// Settings changes the assistant asked for (Ask me, or allowing codes).
    @Published var settingsRequests: [SettingsRequest] = [] { didSet { updateGlyph() } }
    /// What the menu bar glyph shows, kept apart so the status item redraws only when it changes.
    let glyph = MenuBarGlyph()
    @Published var clients: [String] = []
    /// Per assistant: could the app it runs in read chat.db without Veil? (See `ClientCheck`.)
    let clientCheckStore: ClientCheckStore
    @Published var clientChecks: [ClientCheck] = []
    /// "Don't warn me again", per assistant name (UserDefaults; it only quiets a notice).
    let acknowledgements: BypassAcknowledgements
    @Published private(set) var acknowledgedVersion = 0
    /// Other apps with Full Disk Access, read from TCC.db. nil when it couldn't be read.
    @Published var fullDiskAccess: [FullDiskAccessGrant]?
    private let tccDatabases: (system: URL, user: URL?)

    // One-click connect. Paths come from `connectHome`, so demo mode works on fake files.
    let connectTargets: [ConnectClientID: MCPConfigTarget]
    let claudeCode: ClaudeCodeConnector
    @Published var connectStatus: [ConnectClientID: ConnectStatus] = [:]
    @Published var claudeCodeCLI: (cli: URL, path: String?)?
    @Published var connectMessage: [ConnectClientID: String] = [:]
    @Published var connectError: [ConnectClientID: String] = [:]
    @Published var pendingChange: PendingConnectChange?
    /// Bundle id → app name for that list (NSWorkspace live, a fixed table in demo mode).
    private let resolveAppName: @Sendable (String) -> String?
    @Published var contactsStatus: CNAuthorizationStatus = .notDetermined
    @Published var serverError: String?
    /// Messages could be opened but not read (busy, changed by a macOS update, ...).
    @Published var readProblem: String?
    /// A permission change couldn't be saved; shown as an alert.
    @Published var saveError: String?
    private var reloading = false
    @Published var httpError: String?

    /// Demo and snapshot runs keep their own settings, so trying the demo never changes the real app's.
    static let isDemoRun = CommandLine.arguments.contains("--demo") || CommandLine.arguments.contains("--snapshot")
    private static let defaults: UserDefaults = isDemoRun
        ? (UserDefaults(suiteName: "io.github.benlittlle.veil.demo") ?? .standard) : .standard
    @Published var assistantName = defaults.string(forKey: "assistantName") ?? "Assistant" {
        didSet { Self.defaults.set(assistantName, forKey: "assistantName") }
    }
    @Published var httpEnabled = defaults.bool(forKey: "httpEnabled") {
        didSet { Self.defaults.set(httpEnabled, forKey: "httpEnabled") }
    }
    @Published var httpToken = defaults.string(forKey: "httpToken") ?? "" {
        didSet { Self.defaults.set(httpToken, forKey: "httpToken") }
    }
    let httpPort = defaults.object(forKey: "httpPort") as? Int ?? 8765

    // Auto-send
    @Published var autoSendHistory: [AutoSendRecord] = []
    @Published var autoSendNotify = defaults.object(forKey: "autoSendNotify") as? Bool ?? true {
        didSet { Self.defaults.set(autoSendNotify, forKey: "autoSendNotify"); if autoSendNotify { requestNotifications() } }
    }

    // New-message pings
    @Published var webhookEnabled = defaults.bool(forKey: "webhookEnabled") {
        didSet { Self.defaults.set(webhookEnabled, forKey: "webhookEnabled"); applyWebhook() }
    }
    @Published var webhookURL = defaults.string(forKey: "webhookURL") ?? "" {
        didSet { Self.defaults.set(webhookURL, forKey: "webhookURL"); applyWebhook() }
    }
    @Published var webhookHeader = defaults.string(forKey: "webhookHeader") ?? "Authorization" {
        didSet { Self.defaults.set(webhookHeader, forKey: "webhookHeader"); applyWebhook() }
    }
    /// In chats with Activity on, the user's own messages ping too (direction "from_me").
    @Published var webhookPingReplies = defaults.object(forKey: "webhookPingReplies") as? Bool ?? true {
        didSet { Self.defaults.set(webhookPingReplies, forKey: "webhookPingReplies"); applyWebhook() }
    }
    @Published var webhookKeySaved = false
    @Published var webhookLog: [WebhookLogEntry] = []
    @Published var webhookTesting = false

    // Content filter
    @Published var filterStatus: ClassifierStatus = .unavailable("Checking…")
    @Published var filterReview: [String: [Gate.FilterReviewItem]] = [:]
    @Published var filterReviewLoading: Set<String> = []
    @Published var photoStatus: ClassifierStatus = .unavailable("Checking…")
    @Published var photoReview: [String: [Gate.PhotoReviewItem]] = [:]
    /// Small previews for the review list (the user only, in memory).
    @Published var photoThumbs: [Int64: CGImage] = [:]

    // Look & feel
    @Published var appearance = AppearanceChoice(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system {
        didSet { Self.defaults.set(appearance.rawValue, forKey: "appearance"); applyTheme() }
    }
    @Published var accent = AccentChoice(rawValue: defaults.string(forKey: "accent") ?? "") ?? .graphite {
        didSet { Self.defaults.set(accent.rawValue, forKey: "accent"); applyTheme() }
    }
    @Published var surface = SurfaceChoice(rawValue: defaults.string(forKey: "surface") ?? "") ?? .warm {
        didSet { Self.defaults.set(surface.rawValue, forKey: "surface"); applyTheme() }
    }
    /// Changes whenever the theme does, so views can rebuild with the new colors.
    var themeID: String { accent.rawValue + surface.rawValue }

    func applyTheme() {
        Theme.accentChoice = accent
        Theme.surface = surface
        NSApp?.appearance = appearance.nsAppearance
        applyDockIcon()
    }

    /// The Dock icon follows the accent. The icon in Finder (the bundle's AppIcon) stays graphite.
    private func applyDockIcon() {
        guard mode == .live, let app = NSApp,
              let url = accent.iconURL, let image = NSImage(contentsOf: url) else { return }
        app.applicationIconImage = image
    }

    // Open at login
    @Published var loginItemStatus = SMAppService.mainApp.status
    @Published var loginItemError: String?

    func setOpenAtLogin(_ on: Bool) {
        loginItemError = nil
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { loginItemError = error.localizedDescription }
        loginItemStatus = SMAppService.mainApp.status
    }

    var onSendRequested: ((SendRequest) -> Void)?
    var onSettingsRequested: ((SettingsRequest) -> Void)?
    /// The assistant name and ping switches, shared with the gate (the settings tools can change them).
    private let preferences: DefaultsPreferences

    // MARK: Moving over from the app's old name

    /// What happened at launch when Veil looked for an older install. Outcomes only, no data.
    @Published var migration: MigrationReport?
    /// The permissions file is there but its key isn't, so everything is off (see `PermissionStore`).
    @Published var signingKeyMissing = false
    /// The older install's permissions key is still in the Keychain, so the user can bring it over.
    @Published var legacyKeyAvailable = false
    @Published var importingLegacyKeys = false

    static let liveSupportDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Veil")
    static let permissionsKeyService = "Veil permissions key"
    static let webhookKeyService = "Veil webhook key"
    private static let logger = Logger(subsystem: "io.github.benlittlle.veil", category: "migration")

    /// Runs before the model reads any settings. Quits a still-running older install first so its
    /// files aren't moved from under it. Keychain reads here never prompt.
    static func migrateLegacyInstall() -> MigrationReport {
        migratePreviousBundleID()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Legacy.bundleID) {
            app.terminate()
            let deadline = Date().addingTimeInterval(5)
            while !app.isTerminated && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let report = LegacyMigrator(
            oldDir: home.appendingPathComponent("Library/Application Support/\(Legacy.supportFolder)"),
            newDir: liveSupportDir,
            oldSettings: UserDefaults.standard.persistentDomain(forName: Legacy.bundleID),
            newSettings: .standard,
            oldPermissionsKey: KeychainSecretStore(service: Legacy.permissionsKeyService, allowUI: false),
            newPermissionsKey: KeychainSecretStore(service: permissionsKeyService),
            oldWebhookKey: KeychainString(service: Legacy.webhookKeyService, allowUI: false),
            newWebhookKey: KeychainString(service: webhookKeyService)).run()
        logger.log("\(report.summary, privacy: .public)")
        return report
    }

    /// Veil's bundle id before the downloadable release. Its settings (accent, assistant name,
    /// webhook address, …) live under that id, so copy them once, never overwriting a newer value.
    /// The Application Support folder and the Keychain items don't depend on the bundle id; macOS
    /// asks once before the newly signed app may use the existing Keychain items.
    static let previousBundleIDs = ["local.veil.Veil"]
    static func migratePreviousBundleID() {
        let d = UserDefaults.standard, marker = "migratedFromPreviousBundleID"
        guard let me = Bundle.main.bundleIdentifier, !d.bool(forKey: marker) else { return }
        for id in previousBundleIDs where id != me {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { app.terminate() }
            guard let old = d.persistentDomain(forName: id) else { continue }
            var copied = 0
            for (k, v) in old where d.object(forKey: k) == nil { d.set(v, forKey: k); copied += 1 }
            logger.log("copied \(copied, privacy: .public) settings from the previous bundle id")
        }
        d.set(true, forKey: marker)
    }

    /// The user asked to bring over the older install's Keychain items. macOS shows its own prompt for
    /// each one; nothing changes unless they allow it. The permissions file is then checked again.
    func importLegacyKeys() {
        guard mode == .live, signingKeyMissing else { return }
        importingLegacyKeys = true
        DispatchQueue.global(qos: .userInitiated).async {
            let key = LegacyMigrator.copyKey(from: KeychainSecretStore(service: Legacy.permissionsKeyService),
                                             to: KeychainSecretStore(service: Self.permissionsKeyService))
            let webhook = LegacyMigrator.copyString(from: KeychainString(service: Legacy.webhookKeyService),
                                                    to: KeychainString(service: Self.webhookKeyService))
            Self.logger.log("import: permissionsKey=\(String(describing: key), privacy: .public) webhookKey=\(String(describing: webhook), privacy: .public)")
            Task { @MainActor in
                self.importingLegacyKeys = false
                self.gate.permissions.reload()
                self.refreshIntegrity()
                self.webhookKeySaved = !(self.webhookKey?.read() ?? "").isEmpty
                self.applyWebhook()
                if case .unavailable(let why) = key { self.saveError = "Veil couldn't bring over the key (\(why))." }
            }
        }
    }

    private func refreshIntegrity() {
        state = gate.permissions.state
        integrity = gate.permissions.integrity
        signingKeyMissing = gate.permissions.signingKeyMissing
        legacyKeyAvailable = mode == .live && signingKeyMissing
            && KeychainSecretStore(service: Legacy.permissionsKeyService, allowUI: false).exists()
    }

    init(mode: Mode, migration: MigrationReport? = nil) {
        self.mode = mode
        self.migration = migration
        let fm = FileManager.default
        let preferences = DefaultsPreferences(Self.defaults)
        self.preferences = preferences
        switch mode {
        case .live:
            supportDir = Self.liveSupportDir
            socketPath = supportDir.appendingPathComponent("mcp.sock").path
            let contacts = SystemContacts()
            systemContacts = contacts
            let home = fm.homeDirectoryForCurrentUser
            watcher = DatabaseWatcher(databasePath: home.appendingPathComponent("Library/Messages/chat.db").path)
            gate = Gate(
                permissions: PermissionStore(url: supportDir.appendingPathComponent("permissions.json"), secrets: KeychainSecretStore(service: Self.permissionsKeyService)),
                log: AccessLog(url: supportDir.appendingPathComponent("access-log.jsonl")),
                contacts: contacts, sender: AppleScriptSender(),
                autoSends: AutoSendHistory(url: supportDir.appendingPathComponent("auto-sent.jsonl")),
                // Content filter judgement: Apple's on-device model only. Never a server model.
                classifier: AppleOnDeviceClassifier(),
                // Photo checks: the same on-device model looking at the image, Vision text
                // recognition, and SensitiveContentAnalysis when this Mac allows it.
                imageClassifier: AppleOnDeviceImageClassifier(), textRecognizer: VisionTextRecognizer(),
                nudityDetector: SensitiveContentDetector(),
                preferences: preferences,
                openStore: {
                    try MessagesStore(databasePath: home.appendingPathComponent("Library/Messages/chat.db").path,
                                      attachmentsRoot: home.appendingPathComponent("Library/Messages/Attachments"))
                })
            // Its own read-only connection, so polling never waits on an assistant's query.
            webhook = WebhookNotifier(
                permissions: gate.permissions,
                openStore: {
                    try MessagesStore(databasePath: home.appendingPathComponent("Library/Messages/chat.db").path,
                                      attachmentsRoot: home.appendingPathComponent("Library/Messages/Attachments"))
                },
                log: WebhookLog(url: supportDir.appendingPathComponent("webhook-log.jsonl")))
            webhookKey = KeychainString(service: Self.webhookKeyService)
            clientCheckStore = ClientCheckStore(url: supportDir.appendingPathComponent("client-checks.json"))
            acknowledgements = BypassAcknowledgements()
            let apps = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
            connectTargets = [.claudeDesktop: .claudeDesktop(home: home, applications: apps), .cursor: .cursor(home: home, applications: apps)]
            claudeCode = ClaudeCodeConnector(home: home, shellLookup: { ProcessRunner.loginShellLookup("claude") },
                                             run: { ProcessRunner.run($0, $1, env: $2) })
            tccDatabases = (FullDiskAccessList.systemDatabase, FullDiskAccessList.userDatabase)
            resolveAppName = { Self.appName(bundleID: $0) }
        case .demo:
            // Per process, so two demo or snapshot runs at once can't delete each other's files.
            supportDir = fm.temporaryDirectory.appendingPathComponent("Veil-demo-\(getpid())")
            // Demo keys live in memory, so start from a clean folder each time (an old demo
            // permissions file without its key would correctly show as locked).
            try? fm.removeItem(at: supportDir)
            socketPath = supportDir.appendingPathComponent("mcp.sock").path
            systemContacts = nil
            let paths = try! DemoData.build(at: supportDir.appendingPathComponent("fixture"))
            try? DemoData.addFilterExamples(db: paths.db)
            watcher = DatabaseWatcher(databasePath: paths.db.path)
            try? DemoData.addAgedHistory(db: paths.db)
            gate = Gate(
                permissions: PermissionStore(url: supportDir.appendingPathComponent("permissions.json"), secrets: MemorySecretStore()),
                log: AccessLog(url: nil), contacts: StaticContacts(DemoData.contacts), sender: RecordingSender(),
                classifier: DemoClassifier(), imageClassifier: DemoImageClassifier(), textRecognizer: VisionTextRecognizer(),
                preferences: preferences,
                openStore: { try MessagesStore(databasePath: paths.db.path, attachmentsRoot: paths.attachments) })
            webhook = WebhookNotifier(permissions: gate.permissions,
                                      openStore: { try MessagesStore(databasePath: paths.db.path, attachmentsRoot: paths.attachments) },
                                      log: WebhookLog(url: nil))
            webhookKey = nil
            clientCheckStore = ClientCheckStore(url: nil)
            let demoDefaults = UserDefaults(suiteName: "io.github.benlittlle.veil.demo-acknowledgements")!
            demoDefaults.removePersistentDomain(forName: "io.github.benlittlle.veil.demo-acknowledgements")
            acknowledgements = BypassAcknowledgements(defaults: demoDefaults)
            // Demo: a fake home folder. Never the real configs, never the real `claude` CLI.
            let demoHome = supportDir.appendingPathComponent("demo-home")
            Self.buildDemoConnectHome(demoHome)
            let apps = [demoHome.appendingPathComponent("Applications")]
            connectTargets = [.claudeDesktop: .claudeDesktop(home: demoHome, applications: apps), .cursor: .cursor(home: demoHome, applications: apps)]
            claudeCode = ClaudeCodeConnector(home: demoHome, candidates: [], shellLookup: { (nil, nil) },
                                             run: { _, _, _ in (1, "Not available in demo mode") })
            let tcc = supportDir.appendingPathComponent("fixture-tcc/TCC.db")
            try? DemoData.buildTCC(at: tcc, rows: DemoData.demoFullDiskAccess)
            tccDatabases = (tcc, nil)
            resolveAppName = { DemoData.demoAppNames[$0] }
            for (id, a) in DemoData.demoAccess { try? gate.setAccess(a, for: id) }
            // Demo: one assistant whose app has Full Disk Access, one on the web address.
            for c in Self.demoClientChecks { clientCheckStore.record(c) }
            try? gate.setFiltered(true, for: DemoData.ID.alex)
            try? gate.markReviewed([DemoData.ID.therapist, DemoData.ID.family])
        }
        server = MCPServer(gate: gate)
        if httpToken.isEmpty { httpToken = Self.newToken() }

        gate.log.onAppend = { [weak self] _ in Task { @MainActor in self?.logChanged() } }
        gate.onOutboxChange = { [weak self] in Task { @MainActor in self?.syncOutbox() } }
        gate.onSendRequested = { [weak self] r in Task { @MainActor in self?.syncOutbox(); self?.onSendRequested?(r) } }
        gate.autoSends.onChange = { [weak self] in Task { @MainActor in self?.autoSendHistory = self?.gate.autoSends.all ?? [] } }
        gate.onAutoSend = { [weak self] r in Task { @MainActor in self?.notifyAutoSend(r) } }
        gate.onSettingsRequested = { [weak self] r in Task { @MainActor in self?.syncOutbox(); self?.onSettingsRequested?(r) } }
        gate.onSettingsApplied = { [weak self] r in Task { @MainActor in self?.notifySettingsChange(r) } }
        gate.onSettingsChange = { [weak self] in Task { @MainActor in self?.settingsChanged() } }
        gate.onSharingEnded = { [weak self] _ in Task { @MainActor in self?.refreshIntegrity(); self?.syncOutbox() } }
        // Shares whose time ran out while Veil was closed (or the Mac asleep) are locked before anything else.
        gate.expireShares()
        preferences.onChange = { [weak self] in Task { @MainActor in self?.syncPreferences() } }
        autoSendHistory = gate.autoSends.all
        webhook.log.onAppend = { [weak self] in Task { @MainActor in self?.webhookLog = self?.webhook.log.all ?? [] } }
        webhookLog = webhook.log.all
        webhookKeySaved = !(webhookKey?.read() ?? "").isEmpty
        server.onSessionsChange = { [weak self] in Task { @MainActor in self?.clients = self?.server.connectedClients ?? [] } }
        let checks = clientCheckStore
        let acks = acknowledgements
        server.onClientCheck = { acks.update(for: $0); checks.record($0) }
        checks.onChange = { [weak self] in Task { @MainActor in self?.clientChecks = checks.all } }
        clientChecks = checks.all

        applyTheme()
        log = gate.log.all
        refreshIntegrity()
        if mode == .demo { refreshFullDiskAccess(wait: true) }
        refreshConnect(wait: true)
        contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
        if SystemContacts.isAuthorized { reloadContacts() }
        // Names change when the user edits Contacts.
        NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reloadContacts() }
        }
    }

    /// Reads the Contacts database off the main thread, then refreshes the chat list.
    private func reloadContacts() {
        guard let contacts = systemContacts else { return }
        DispatchQueue.global(qos: .utility).async {
            contacts.reload()
            Task { @MainActor in self.reload() }
        }
    }

    var showsContactNames: Bool { mode == .demo || SystemContacts.isAuthorized }

    func start() {
        // Ask for Contacts up front so chats show names (macOS shows its own prompt once).
        if mode == .live && contactsStatus == .notDetermined { requestContacts() }
        reloadNow()
        do {
            let s = UnixSocketServer(path: socketPath, server: server)
            try s.start(); socket = s
        } catch { serverError = error.localizedDescription }
        applyHTTP()
        applyWebhook()
        // New messages: Messages writing to chat.db wakes the pings right away, and the chat list
        // and the filter's background pass shortly after.
        let webhook = self.webhook
        watcher.onChange { [weak self] in
            webhook.poke()
            Task { @MainActor in self?.databaseChanged() }
        }
        watcher.start()
        webhook.start()
        refreshFullDiskAccess()
        // Content filter: judge new messages in filtered chats ahead of time, on this Mac.
        refreshFilterStatus()
        prewarmPhotoChecks()
        warmFilter()
        // A slow fallback in case a file event is missed, and for the model becoming available.
        // Each step does nothing when nothing changed.
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reload(); self?.gate.pruneFinishedSends()
                // Settings requests nobody answered expire; take them off the screen.
                self?.gate.expireSettingsRequests()
                self?.gate.expireShares()
                self?.refreshFilterStatus(); self?.warmFilter()
            }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
    }

    func stop() { watcher.stop(); socket?.stop(); http?.stop(); webhook.stop() }

    /// Messages wrote to chat.db. Writes can go on for minutes (an iCloud sync, say), so the chat
    /// list and the filter's background pass follow at most every 10 seconds. Pings don't wait for this.
    private func databaseChanged() {
        guard !changePending else { return }
        changePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.changePending = false
                self.reload(); self.warmFilter()
            }
        }
    }

    func reload() {
        // Pick up a Contacts permission granted later in System Settings.
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status != contactsStatus {
            contactsStatus = status
            if SystemContacts.isAuthorized { reloadContacts() }
        }
        // Database work happens off the main thread so the UI never stalls.
        guard !reloading else { return }
        reloading = true
        let gate = self.gate
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Self.load(gate)
            Task { @MainActor in self.reloading = false; self.apply(result) }
        }
    }

    /// Blocking version, used once at launch (to decide whether to show onboarding) and for snapshots.
    func reloadNow() { apply(Self.load(gate)) }

    private typealias LoadResult = (convs: [Conversation]?, openError: String?, readError: String?)

    nonisolated private static func load(_ gate: Gate) -> LoadResult {
        do {
            _ = try gate.messagesStore()   // fails only when chat.db can't be opened (no Full Disk Access)
            do { return (try gate.conversations(), nil, nil) } catch { return (nil, nil, "\(error)") }
        } catch { return (nil, "\(error)", nil) }
    }

    /// Only real changes are published, so open views don't redraw for nothing.
    private func apply(_ r: LoadResult) {
        if diskAccessProblem != r.openError { diskAccessProblem = r.openError }
        if readProblem != r.readError { readProblem = r.readError }
        if let c = r.convs, c != conversations { conversations = c }
    }

    // MARK: Permissions (UI only)

    func access(_ id: String) -> ChatAccess { state.chats[id] ?? .none }

    func binding(_ id: String, _ key: WritableKeyPath<ChatAccess, Bool>) -> Binding<Bool> {
        Binding(get: { self.access(id)[keyPath: key] },
                // Turning Send off also turns auto-send off; turning it back on never revives it. Only this
                // switch changes, so the time limit and everything else stay as they are.
                set: { v in self.setSwitches([key: v], for: id) })
    }

    func setAccess(_ a: ChatAccess, for id: String) { save { try self.gate.setAccess(a, for: id) } }
    /// Flips switches on the live settings. A duration picked while nothing was shared starts with them.
    func setSwitches(_ values: [WritableKeyPath<ChatAccess, Bool>: Bool], for id: String) {
        let start = pendingShareFor[id]
        save { try self.gate.setSwitches(values, for: id, startFor: start) }
        if access(id).hasAnySwitch { pendingShareFor[id] = nil }
    }
    func setAutoSend(_ on: Bool, for id: String) {
        setSwitches([\.autoSend: on], for: id)
        if access(id).autoSend && autoSendNotify { requestNotifications() }
    }

    // MARK: History and time limits (UI only; the assistant asks through the settings tools)

    /// "For:" picked on a chat that isn't shared yet. Applied when the first switch goes on.
    @Published var pendingShareFor: [String: ShareDuration] = [:]
    func setHistory(_ w: HistoryWindow, for id: String) { save { try self.gate.setHistory(w, for: id) } }
    /// A new end time counted from now (Always removes it).
    func shareFor(_ d: ShareDuration, for id: String) {
        let end = d.expiry(from: Date())
        save { try self.gate.setShareExpiry(end, for: id) }
    }
    /// Pushes the end time back (from whichever is later, now or the current end).
    func extendShare(by seconds: TimeInterval, for id: String) {
        let from = max(Date(), access(id).expires ?? Date())
        save { try self.gate.setShareExpiry(from.addingTimeInterval(seconds), for: id) }
    }
    func endSharing(_ id: String) { save { try self.gate.endSharing(id) }; syncOutbox() }
    func setAutoSendStopped(_ stopped: Bool) { save { try self.gate.setAutoSendStopped(stopped) } }
    func setAutoSendLimit(_ l: AutoSendLimit) { save { try self.gate.setAutoSendLimit(l) } }
    var autoSendChats: [Conversation] { conversations.filter { let a = access($0.id); return a.send && a.autoSend && !a.hidden } }
    var limitText: String {
        let l = state.effectiveAutoSendLimit
        return "\(l.count) \(l.count == 1 ? "message" : "messages") every \(l.minutes) \(l.minutes == 1 ? "minute" : "minutes")"
    }
    func clearAutoSendHistory() { gate.autoSends.clear() }

    /// Notifications need a real app bundle (not `swift run`).
    private var canNotify: Bool { mode == .live && Bundle.main.bundleIdentifier != nil }

    func requestNotifications() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }

    private func notifyAutoSend(_ r: AutoSendRecord) {
        notify(id: r.id.uuidString, title: r.outcome == .sent ? "\(assistantName) sent a message to \(r.chatName)" : "Auto-send to \(r.chatName) failed",
               body: String(r.text.prefix(180)))
    }

    /// Apply directly: one notification per change, under the same "Notify me" setting as auto-send.
    private func notifySettingsChange(_ r: SettingsRequest) {
        notify(id: r.id, title: "\(assistantName) changed settings\(r.chatName.map { " for \($0)" } ?? "")",
               body: String(r.shortSummary.prefix(180)))
    }

    private func notify(id: String, title: String, body: String) {
        guard autoSendNotify, canNotify else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: c, trigger: nil))
    }

    // MARK: Assistant can change settings (the mode itself is UI only)

    func setAgentSettings(_ mode: AgentSettingsMode) {
        save { try self.gate.setAgentSettings(mode) }
        syncOutbox()
        if mode == .direct && autoSendNotify { requestNotifications() }
    }

    var waitingSettings: [SettingsRequest] { settingsRequests.filter { $0.status == .pending } }

    func approveSettings(_ id: String) {
        let gate = self.gate
        DispatchQueue.global(qos: .userInitiated).async {
            gate.approveSettings(id)
            Task { @MainActor in self.syncOutbox(); self.refreshIntegrity() }
        }
    }
    func declineSettings(_ id: String) { gate.declineSettings(id); syncOutbox() }

    /// The settings tools (or an approval) changed something: show it and re-check filtered chats.
    private func settingsChanged() {
        refreshIntegrity()
        syncOutbox()
        syncPreferences()
        for id in filterReview.keys { loadFilterReview(id) }
        warmFilter()
    }

    private func syncPreferences() {
        if assistantName != preferences.assistantName { assistantName = preferences.assistantName }
        if webhookEnabled != preferences.newMessagePings { webhookEnabled = preferences.newMessagePings }
        if webhookPingReplies != preferences.pingWhenIReply { webhookPingReplies = preferences.pingWhenIReply }
    }

    // MARK: Content filter (UI only)

    func setFiltered(_ on: Bool, for id: String) { save { try self.gate.setFiltered(on, for: id) }; filterChanged(id) }
    func setFilterProfile(_ p: FilterPolicy) { save { try self.gate.setFilterProfile(p) }; filterChanged(nil) }
    func setChatFilterPolicy(_ p: FilterPolicy?, for id: String) { save { try self.gate.setChatFilterPolicy(p, for: id) }; filterChanged(id) }
    func setFilterAllowed(_ allowed: Bool, message: Int64, in id: String) {
        save { try self.gate.setFilterAllowed(allowed, message: message, in: id) }; filterChanged(id)
    }
    func alwaysAllow(_ c: FilterCategory, in id: String) { save { try self.gate.alwaysAllow(c, in: id) }; filterChanged(id) }
    func setPhotoAllowed(_ allowed: Bool, attachment: Int64, in id: String) {
        save { try self.gate.setPhotoAllowed(allowed, attachment: attachment, in: id) }; filterChanged(id)
    }

    /// The settings a chat uses (its own, or the default profile).
    func filterPolicy(_ id: String) -> FilterPolicy { access(id).filterPolicy ?? state.effectiveFilterProfile }

    func refreshFilterStatus() {
        let text = gate.filter.modelStatus, photo = gate.photos.status
        if filterStatus != text { filterStatus = text }
        if photoStatus != photo { photoStatus = photo }
    }

    private func filterChanged(_ id: String?) {
        if let id { loadFilterReview(id) } else { for id in filterReview.keys { loadFilterReview(id) } }
        prewarmPhotoChecks()
        warmFilter()
    }

    /// Loads text recognition ahead of the first photo, but only once some chat checks photos,
    /// so Macs that don't use photo checks never load it.
    private func prewarmPhotoChecks() {
        let s = gate.permissions.state
        if s.chats.contains(where: { id, a in a.attachments && !a.hidden && s.filterPolicy(for: id)?.attachments == .check }) {
            gate.photos.prewarm()
        }
    }

    /// Judges recent messages in filtered chats in the background, so the assistant's requests stay fast.
    func warmFilter() {
        let gate = self.gate
        DispatchQueue.global(qos: .utility).async { gate.warmFilterCache() }
    }

    /// The user's review of what the filter changed in one chat. Computed on this Mac, shown only here.
    func loadFilterReview(_ id: String, wait: Bool = false) {
        guard access(id).filtered else { filterReview[id] = []; photoReview[id] = []; return }
        filterReviewLoading.insert(id)
        let gate = self.gate
        // Photos and their previews, worked out off the main thread.
        let load = { () -> ([Gate.FilterReviewItem], [Gate.PhotoReviewItem], [Int64: CGImage]) in
            let items = (try? gate.filterReview(chatID: id)) ?? []
            let photos = (try? gate.photoReview(chatID: id)) ?? []
            var thumbs: [Int64: CGImage] = [:]
            for p in photos { thumbs[p.id] = gate.photoThumbnail(attachmentID: p.id, chatID: id) }
            return (items, photos, thumbs)
        }
        if wait {
            // Snapshots only. The work still runs off the main thread (Vision text recognition can
            // need the main thread while it starts up), and the main run loop keeps turning meanwhile.
            nonisolated(unsafe) var result: ([Gate.FilterReviewItem], [Gate.PhotoReviewItem], [Int64: CGImage])?
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .userInitiated).async { result = load(); done.signal() }
            while done.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
            let (items, photos, thumbs) = result ?? ([], [], [:])
            filterReview[id] = items; photoReview[id] = photos; photoThumbs.merge(thumbs) { $1 }
            filterReviewLoading.remove(id)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let (items, photos, thumbs) = load()
            Task { @MainActor in
                self.filterReview[id] = items; self.photoReview[id] = photos; self.photoThumbs.merge(thumbs) { $1 }
                self.filterReviewLoading.remove(id)
            }
        }
    }

    func setPaused(_ p: Bool) { save { try self.gate.setPaused(p) } }
    func markReviewed(_ ids: [String]) { save { try self.gate.markReviewed(ids) } }

    /// After a tamper warning: start over from everything-off and re-sign.
    func resetPermissions() { save { try self.gate.resetAll() }; syncOutbox() }

    private func save(_ change: () throws -> Void) {
        do { try change() } catch { saveError = error.localizedDescription }
        refreshIntegrity()
    }

    func clearLog() { gate.log.clear(); log = [] }

    private var logRefreshPending = false
    /// A burst of requests refreshes the activity list once, not once per request.
    private func logChanged() {
        guard !logRefreshPending else { return }
        logRefreshPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.logRefreshPending = false
                self.log = self.gate.log.all
            }
        }
    }

    private func updateGlyph() {
        let quiet = waitingSends.isEmpty && waitingSettings.isEmpty && failedSends.isEmpty
        let style: VeilGlyph.Style = state.paused ? .paused : (quiet ? .normal : .attention)
        if glyph.style != style { glyph.style = style }
    }

    var newChats: [Conversation] { conversations.filter { !state.reviewed.contains($0.id) } }
    var sharedCount: Int { conversations.filter { access($0.id).anyEnabled }.count }
    var waitingSends: [SendRequest] { sends.filter { $0.status == .waiting } }

    // MARK: Outbox

    private func syncOutbox() { drafts = gate.drafts; sends = gate.sends; settingsRequests = gate.settingsRequests }

    func approve(_ id: String) {
        let gate = self.gate
        DispatchQueue.global(qos: .userInitiated).async {
            gate.approve(id)
            Task { @MainActor in
                self.syncOutbox()
                // The prompt is gone by now, so say so if Messages didn't take it.
                if self.failedSends.contains(where: { $0.id == id }) { self.onSendFailed?() }
            }
        }
    }

    /// Sends that Messages didn't take (approved or auto-sent), until the user dismisses them or
    /// they're forgotten after an hour. The text stays here so it can be copied and sent by hand.
    var failedSends: [SendRequest] {
        sends.filter { if case .failed = $0.status { return !dismissedFailures.contains($0.id) }; return false }
    }
    @Published private var dismissedFailures: Set<String> = [] { didSet { updateGlyph() } }
    var onSendFailed: (() -> Void)?
    func dismissFailure(_ id: String) { dismissedFailures.insert(id) }
    func decline(_ id: String) { gate.decline(id); syncOutbox() }
    func discardDraft(_ id: String) { gate.discardDraft(id); syncOutbox() }

    // MARK: Contacts

    func requestContacts() {
        systemContacts?.requestAccess { _ in
            Task { @MainActor in
                self.contactsStatus = CNContactStore.authorizationStatus(for: .contacts)
                self.reload()
            }
        }
    }

    // MARK: Bypass warnings

    static let demoClientChecks = [
        ClientCheck(name: "Goose", transport: .relay, reach: .readable, lastSeen: Date().addingTimeInterval(-600)),
        ClientCheck(name: "Web Helper", transport: .http, reach: .cantCheckHTTP, lastSeen: Date().addingTimeInterval(-7200)),
    ]

    /// Assistants whose app can open chat.db without Veil and that the user hasn't acknowledged.
    var bypassWarnings: [ClientCheck] { _ = acknowledgedVersion; return clientChecks.filter(acknowledgements.needsNotice) }
    func isAcknowledged(_ c: ClientCheck) -> Bool { _ = acknowledgedVersion; return acknowledgements.isAcknowledged(c.name) }
    func acknowledge(_ c: ClientCheck) { acknowledgements.acknowledge(c.name); acknowledgedVersion += 1 }
    func unacknowledge(_ c: ClientCheck) { acknowledgements.unacknowledge(c.name); acknowledgedVersion += 1 }
    func isConnected(_ c: ClientCheck) -> Bool { clients.contains(c.name) }
    func forgetClientCheck(_ name: String) { clientCheckStore.forget(name) }
    /// An app in the Full Disk Access list worth pointing out: one a seen assistant probably runs in, or an AI app.
    func isHighlighted(_ g: FullDiskAccessGrant) -> Bool { g.kind == .ai || connectedHost(g) != nil }
    func connectedHost(_ g: FullDiskAccessGrant) -> ClientCheck? { clientChecks.first { g.matches(clientName: $0.name) } }

    /// Reads who has Full Disk Access (read-only, off the main thread). Hidden if it can't be read.
    func refreshFullDiskAccess(wait: Bool = false) {
        let dbs = tccDatabases, resolve = resolveAppName
        let read = { () -> [FullDiskAccessGrant]? in
            FullDiskAccessList.read(system: dbs.system, user: dbs.user, resolveName: resolve,
                                    excluding: Set([Bundle.main.bundleIdentifier].compactMap { $0 }))
        }
        if wait { fullDiskAccess = read(); return }
        DispatchQueue.global(qos: .utility).async {
            let list = read()
            Task { @MainActor in self.fullDiskAccess = list }
        }
    }

    nonisolated static func appName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    static func openFullDiskAccessSettings() { openPrivacy("Privacy_AllFiles") }
    static func openFilesAndFoldersSettings() { openPrivacy("Privacy_FilesAndFolders") }
    static func openPrivacy(_ anchor: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    // MARK: One-click connect

    /// Demo files: Claude Desktop with another server, Cursor pointing at a copy that's gone.
    static func buildDemoConnectHome(_ home: URL) {
        let fm = FileManager.default
        try? fm.createDirectory(at: home.appendingPathComponent("Applications/Claude.app"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: home.appendingPathComponent("Applications/Cursor.app"), withIntermediateDirectories: true)
        let claude = home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
        let cursor = home.appendingPathComponent(".cursor/mcp.json")
        for (url, text) in [
            (claude, #"{"mcpServers": {"files": {"command": "npx", "args": ["-y", "@example/files-server", "~/Documents"]}}}"#),
            (cursor, #"{"mcpServers": {"veil": {"command": "/Users/demo/Downloads/Veil.app/Contents/MacOS/veil-mcp"}}}"#),
        ] {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(text.utf8).write(to: url)
        }
    }

    /// The relay isn't inside an installed Veil.app (e.g. `swift run`), so the path may change on rebuild.
    var bridgeIsInApp: Bool { bridgePath.hasSuffix(".app/Contents/MacOS/veil-mcp") }

    func status(_ id: ConnectClientID) -> ConnectStatus { connectStatus[id] ?? .notInstalled }

    /// Re-reads every client's status. The login-shell lookup for `claude` runs off the main thread.
    func refreshConnect(wait: Bool = false) {
        let command = bridgePath
        var s: [ConnectClientID: ConnectStatus] = [:]
        for (id, t) in connectTargets { s[id] = t.status(command: command) }
        let cc = claudeCode
        let lookup = { () -> ((cli: URL, path: String?)?, ConnectStatus) in
            let found = cc.findCLI()
            return (found, cc.status(command: command, cliFound: found != nil))
        }
        if wait {
            let (found, st) = lookup()
            s[.claudeCode] = st; claudeCodeCLI = found; connectStatus = s
            return
        }
        s[.claudeCode] = connectStatus[.claudeCode]
        connectStatus = s
        DispatchQueue.global(qos: .userInitiated).async {
            let (found, st) = lookup()
            Task { @MainActor in self.claudeCodeCLI = found; self.connectStatus[.claudeCode] = st }
        }
    }

    /// Works out the change and asks for confirmation (the sheet on Connect). Nothing is written yet.
    func propose(_ action: ConfigPlan.Action, for id: ConnectClientID) {
        connectError[id] = nil; connectMessage[id] = nil
        if id == .claudeCode {
            pendingChange = PendingConnectChange(client: id, action: action, plan: nil,
                                                 commands: ClaudeCodeConnector.commands(action, command: bridgePath).map { ClaudeCodeConnector.commandLine($0) })
            return
        }
        guard let target = connectTargets[id] else { return }
        do { pendingChange = PendingConnectChange(client: id, action: action, plan: try target.plan(action, command: bridgePath), commands: []) }
        catch { connectError[id] = error.localizedDescription }
    }

    /// The user confirmed: back up and write (or run the Claude Code CLI), then re-check.
    func confirm(_ change: PendingConnectChange) {
        pendingChange = nil
        let id = change.client
        let done = { (error: Error?, backup: URL?) in
            if let error { self.connectError[id] = error.localizedDescription }
            else {
                let hint = id == .claudeCode ? self.claudeCode.restartHint : self.connectTargets[id]?.restartHint ?? ""
                let what = change.action == .remove ? "Removed." : change.action == .fix ? "Fixed." : "Added."
                self.connectMessage[id] = [what, hint, backup.map { "Backup: \($0.lastPathComponent)" }].compactMap { $0 }.joined(separator: " ")
            }
            self.refreshConnect()
        }
        if let plan = change.plan {
            do { done(nil, try MCPConfigEditor.apply(plan)) } catch { done(error, nil) }
            return
        }
        guard let found = claudeCodeCLI else { connectError[id] = "Claude Code's command-line tool wasn't found."; return }
        let cc = claudeCode, command = bridgePath
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Error?
            do { try cc.perform(change.action, command: command, cli: found.cli, loginPath: found.path); result = nil } catch { result = error }
            Task { @MainActor in done(result, nil) }
        }
    }

    // MARK: HTTP

    func applyHTTP() {
        http?.stop(); http = nil; httpError = nil
        guard httpEnabled else { return }
        let s = LocalHTTPServer(port: UInt16(clamping: httpPort), token: httpToken, server: server)
        do { try s.start(); http = s } catch { httpError = error.localizedDescription }
    }

    func rotateToken() { httpToken = Self.newToken(); applyHTTP() }

    static func newToken() -> String {
        var b = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b).base64EncodedString().replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
    }

    // MARK: New-message pings

    /// Shown under the settings when pings are on but can't be sent yet.
    var webhookProblem: String? {
        guard webhookEnabled || !webhookURL.isEmpty else { return nil }
        if let p = WebhookConfig.problem(url: webhookURL, headerName: webhookHeader) { return p }
        return webhookKeySaved ? nil : "Paste the key from your assistant's webhook and press Save."
    }

    private var webhookConfig: WebhookConfig? {
        guard WebhookConfig.problem(url: webhookURL, headerName: webhookHeader) == nil,
              let url = URL(string: webhookURL.trimmingCharacters(in: .whitespaces)),
              let key = webhookKey?.read(), !key.isEmpty else { return nil }
        return WebhookConfig(url: url, headerName: webhookHeader, key: key, pingReplies: webhookPingReplies)
    }

    func applyWebhook() {
        if mode == .demo { webhook.configure(Self.demoWebhook); return }
        webhook.configure(webhookEnabled ? webhookConfig : nil)
    }

    /// Demo mode only: pings to a test server named by `VEIL_DEMO_WEBHOOK` (for example a local one),
    /// with a made-up key. Never the saved settings or the Keychain.
    private static var demoWebhook: WebhookConfig? {
        guard let s = ProcessInfo.processInfo.environment["VEIL_DEMO_WEBHOOK"],
              WebhookConfig.problem(url: s, headerName: "Authorization") == nil, let url = URL(string: s) else { return nil }
        return WebhookConfig(url: url, headerName: "Authorization", key: "demo")
    }

    func saveWebhookKey(_ key: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty, let store = webhookKey else { return }
        do { try store.write(k); webhookKeySaved = true } catch { saveError = error.localizedDescription }
        applyWebhook()
    }

    func removeWebhookKey() { webhookKey?.delete(); webhookKeySaved = false; applyWebhook() }

    func sendTestPing() {
        guard let cfg = webhookConfig else { return }
        webhookTesting = true
        webhook.sendTest(cfg) { _ in Task { @MainActor in self.webhookTesting = false } }
    }

    func clearWebhookLog() { webhook.log.clear() }

    func chatName(_ id: String) -> String { conversations.first { $0.id == id }?.displayName ?? id }

    var bridgePath: String {
        // The relay sits next to the app's own executable (inside the .app, or in .build when run with swift run).
        Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("veil-mcp").path
    }

    func copy(_ s: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) }
}

/// The assistant name and ping switches, read and written straight from UserDefaults (which is
/// thread-safe), so the gate can use them from MCP threads. The model mirrors them for the UI.
final class DefaultsPreferences: AppPreferences, @unchecked Sendable {
    private let d: UserDefaults
    var onChange: (() -> Void)?
    init(_ d: UserDefaults) { self.d = d }
    var assistantName: String { d.string(forKey: "assistantName") ?? "Assistant" }
    var newMessagePings: Bool { d.bool(forKey: "webhookEnabled") }
    var pingWhenIReply: Bool { d.object(forKey: "webhookPingReplies") as? Bool ?? true }
    func update(assistantName: String?, newMessagePings: Bool?, pingWhenIReply: Bool?) {
        if let assistantName { d.set(assistantName, forKey: "assistantName") }
        if let newMessagePings { d.set(newMessagePings, forKey: "webhookEnabled") }
        if let pingWhenIReply { d.set(pingWhenIReply, forKey: "webhookPingReplies") }
        onChange?()
    }
}

enum ConnectClientID: String, CaseIterable, Identifiable {
    case claudeDesktop, cursor, claudeCode
    var id: String { rawValue }
    var name: String {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .cursor: return "Cursor"
        case .claudeCode: return "Claude Code"
        }
    }
}

/// A change waiting for the user's OK on the Connect screen.
struct PendingConnectChange: Identifiable {
    let id = UUID()
    let client: ConnectClientID
    let action: ConfigPlan.Action
    /// For config files: exactly what will be written.
    let plan: ConfigPlan?
    /// For Claude Code: the commands Veil will run.
    let commands: [String]
}

/// The menu bar glyph's state, observed on its own by the always-visible status item.
@MainActor final class MenuBarGlyph: ObservableObject {
    @Published var style: VeilGlyph.Style = .normal
}

extension Conversation {
    var subtitle: String {
        if isGroup { return participants.map(\.label).joined(separator: ", ") }
        let p = participants.first
        return p?.name != nil ? (p?.handle ?? "") : "Not in your contacts"
    }
}
