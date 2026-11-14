import Foundation

/// One app or tool that macOS lists as having Full Disk Access, and so can read chat.db without Veil.
public struct FullDiskAccessGrant: Equatable, Sendable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case ai, terminal, editor, commandLine, other
        public var label: String {
            switch self {
            case .ai: return "AI app"
            case .terminal: return "Terminal"
            case .editor: return "Code editor"
            case .commandLine: return "Command-line tool"
            case .other: return ""
            }
        }
    }
    /// A bundle id, or an executable path for command-line tools.
    public let client: String
    public let isPath: Bool
    public let name: String
    public let kind: Kind
    public var id: String { client }
    /// Assistants usually run in one of these, so they're shown first and highlighted.
    public var isLikelyAssistantHost: Bool { kind != .other }

    public init(client: String, isPath: Bool, name: String, kind: Kind) {
        self.client = client; self.isPath = isPath; self.name = name; self.kind = kind
    }
}

/// Reads macOS's privacy database (TCC.db) **read-only** to list who has Full Disk Access.
///
/// Veil can do this only because it has Full Disk Access itself. It never writes to TCC.db: the
/// file is opened with `SQLITE_OPEN_READONLY` and `PRAGMA query_only`. The schema differs between
/// macOS versions, so anything unexpected returns nil and the UI simply hides the list.
public enum FullDiskAccessList {
    public static let service = "kTCCServiceSystemPolicyAllFiles"
    public static let systemDatabase = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")
    public static var userDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
    }

    /// Grants from the system database, plus the user database if it has any. Returns nil when the
    /// system database can't be read or its layout isn't one Veil understands.
    /// - Parameters:
    ///   - resolveName: bundle id → app name (NSWorkspace in the app; a table in tests and demo mode).
    ///   - excluding: clients to leave out (Veil itself).
    public static func read(system: URL, user: URL?, resolveName: (String) -> String? = { _ in nil },
                            excluding: Set<String> = []) -> [FullDiskAccessGrant]? {
        guard let systemRows = try? rows(in: system) else { return nil }
        let userRows = user.flatMap { try? rows(in: $0) } ?? []
        var seen = Set<String>()
        var out: [FullDiskAccessGrant] = []
        for r in systemRows + userRows where !seen.contains(r.client) && !excluding.contains(r.client) && !isVeil(r.client) {
            seen.insert(r.client)
            out.append(grant(client: r.client, isPath: r.isPath, resolveName: resolveName))
        }
        // Likely assistant hosts first, then by name.
        let order = FullDiskAccessGrant.Kind.allCases
        return out.sorted {
            (order.firstIndex(of: $0.kind)!, $0.name.lowercased()) < (order.firstIndex(of: $1.kind)!, $1.name.lowercased())
        }
    }

    struct Row { let client: String; let isPath: Bool }

    /// Allowed Full Disk Access rows from one TCC.db. Throws if it can't be opened or isn't a known layout.
    static func rows(in db: URL) throws -> [Row] {
        let sql = try SQLiteDB(path: db.path, readOnly: true)
        let columns = Set(try sql.query("PRAGMA table_info(access)").compactMap { $0.str("name") })
        guard columns.contains("service"), columns.contains("client") else { throw SQLiteDB.Failure(description: "unknown TCC layout") }
        // macOS 11 and later: auth_value (2 = allowed). Before that: allowed (1 = allowed).
        let allowed: String
        if columns.contains("auth_value") { allowed = "auth_value = 2" }
        else if columns.contains("allowed") { allowed = "allowed = 1" }
        else { throw SQLiteDB.Failure(description: "unknown TCC layout") }
        let type = columns.contains("client_type") ? "client_type" : "NULL AS client_type"
        return try sql.query("SELECT client, \(type) FROM access WHERE service = ? AND \(allowed)", [.text(service)]).compactMap { r in
            guard let client = r.str("client"), !client.isEmpty else { return nil }
            let isPath = r.int("client_type").map { $0 == 1 } ?? client.hasPrefix("/")
            return Row(client: client, isPath: isPath)
        }
    }

    static func isVeil(_ client: String) -> Bool {
        ["io.github.benlittlle.veil", "local.veil.Veil", Legacy.bundleID].contains(client) || client.contains("/Veil.app/")
    }

    static func grant(client: String, isPath: Bool, resolveName: (String) -> String?) -> FullDiskAccessGrant {
        let name: String
        if isPath {
            // /Applications/Foo.app/Contents/MacOS/foo → Foo; /opt/homebrew/bin/node → node
            if let app = client.components(separatedBy: "/").first(where: { $0.hasSuffix(".app") }) { name = String(app.dropLast(4)) }
            else { name = knownNames[client] ?? (client as NSString).lastPathComponent }
        } else {
            name = resolveName(client) ?? knownNames[client] ?? client
        }
        return FullDiskAccessGrant(client: client, isPath: isPath, name: name, kind: kind(client: client, isPath: isPath, name: name))
    }

    static func kind(client: String, isPath: Bool, name: String) -> FullDiskAccessGrant.Kind {
        let lower = name.lowercased()
        let base = (client as NSString).lastPathComponent.lowercased()
        if aiIDs.contains(client) || aiWords.contains(where: { lower.contains($0) }) || (isPath && aiTools.contains(base)) { return .ai }
        if terminalIDs.contains(client) || terminalWords.contains(where: { lower.contains($0) }) { return .terminal }
        if editorIDs.contains(client) || client.hasPrefix("com.jetbrains.") { return .editor }
        if isPath && commandLineTools.contains(base) { return .commandLine }
        return .other
    }

    static let aiIDs: Set<String> = [
        "com.anthropic.claudefordesktop", "com.openai.chat", "com.openai.codex", "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf", "ai.perplexity.mac", "ai.elementlabs.lmstudio", "com.electron.ollama", "com.google.GeminiMacOS",
    ]
    static let aiWords = ["claude", "chatgpt", "openai", "cursor", "windsurf", "copilot", "gemini", "grok", "ollama",
                          "lm studio", "perplexity", "codex", "goose", "cline", "msty"]
    static let aiTools: Set<String> = ["claude", "codex", "gemini", "goose", "aider", "ollama", "opencode"]
    static let terminalIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "dev.warp.Warp", "net.kovidgoyal.kitty",
        "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.mitchellh.ghostty",
        "com.raphaelamorim.rio", "com.termius-dmg.mac", "/usr/libexec/sshd-keygen-wrapper",
    ]
    static let terminalWords = ["terminal", "iterm", "warp", "kitty", "alacritty", "wezterm", "ghostty"]
    static let editorIDs: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.visualstudio.code.oss", "com.vscodium", "dev.zed.Zed",
        "dev.zed.Zed-Preview", "com.sublimetext.4", "com.sublimetext.3", "com.apple.dt.Xcode", "com.panic.Nova", "com.barebones.bbedit",
    ]
    static let commandLineTools: Set<String> = ["node", "python", "python3", "bun", "deno", "ruby", "bash", "zsh", "sh", "fish", "uv", "npx"]
    static let knownNames: [String: String] = [
        "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm", "dev.warp.Warp-Stable": "Warp",
        "com.mitchellh.ghostty": "Ghostty", "net.kovidgoyal.kitty": "kitty", "com.microsoft.VSCode": "Visual Studio Code",
        "com.todesktop.230313mzl4w4u92": "Cursor", "com.anthropic.claudefordesktop": "Claude", "com.openai.chat": "ChatGPT",
        "com.exafunction.windsurf": "Windsurf", "dev.zed.Zed": "Zed", "com.apple.dt.Xcode": "Xcode",
        "/usr/libexec/sshd-keygen-wrapper": "Remote Login (SSH)",
    ]
}

extension DemoData {
    /// One row for a fake TCC.db: (service, client, client_type, allowed).
    public struct TCCRow: Sendable {
        public let service: String, client: String, clientType: Int, allowed: Bool
        public init(_ client: String, path: Bool = false, service: String = FullDiskAccessList.service, allowed: Bool = true) {
            self.service = service; self.client = client; self.clientType = path ? 1 : 0; self.allowed = allowed
        }
    }

    /// Full Disk Access grants shown in demo mode.
    public static let demoFullDiskAccess: [TCCRow] = [
        TCCRow("io.github.benlittlle.veil"), TCCRow("com.example.grokbot"), TCCRow("com.googlecode.iterm2"),
        TCCRow("com.anthropic.claudefordesktop", service: "kTCCServiceAccessibility"),
        TCCRow("/opt/homebrew/bin/node", path: true), TCCRow("com.example.photosync"), TCCRow("com.apple.Terminal", allowed: false),
    ]
    public static let demoAppNames: [String: String] = [
        "com.example.grokbot": "Grok Bot", "com.googlecode.iterm2": "iTerm", "com.example.photosync": "PhotoSync",
    ]

    /// Builds a fake TCC.db. `legacy` uses the pre-macOS 11 layout (`allowed` instead of `auth_value`).
    public static func buildTCC(at url: URL, rows: [TCCRow], legacy: Bool = false) throws {
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let db = try SQLiteDB(path: url.path, readOnly: false)
        if legacy {
            try db.query("CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL, allowed INTEGER NOT NULL, prompt_count INTEGER NOT NULL, csreq BLOB, PRIMARY KEY (service, client, client_type))")
            for r in rows {
                try db.query("INSERT INTO access VALUES (?, ?, ?, ?, 0, NULL)", [.text(r.service), .text(r.client), .int(Int64(r.clientType)), .int(r.allowed ? 1 : 0)])
            }
        } else {
            try db.query("""
                CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL, auth_value INTEGER NOT NULL,
                  auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, csreq BLOB, policy_id INTEGER, indirect_object_identifier_type INTEGER,
                  indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED', indirect_object_code_identity BLOB, flags INTEGER,
                  last_modified INTEGER NOT NULL DEFAULT 0, pid INTEGER, pid_version INTEGER, boot_uuid TEXT NOT NULL DEFAULT 'UNUSED',
                  last_reminded INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (service, client, client_type, indirect_object_identifier))
                """)
            for r in rows {
                try db.query("INSERT INTO access (service, client, client_type, auth_value, auth_reason, auth_version) VALUES (?, ?, ?, ?, 4, 1)",
                             [.text(r.service), .text(r.client), .int(Int64(r.clientType)), .int(r.allowed ? 2 : 0)])
            }
        }
    }
}
