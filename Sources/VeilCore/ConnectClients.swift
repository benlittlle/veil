import Foundation

/// Where an MCP client stands with Veil.
public enum ConnectStatus: Equatable, Sendable {
    case notInstalled
    case notConnected
    case connected
    /// A `veil` entry exists but runs something else: an old or moved copy, or one that's gone.
    case otherPath(String, exists: Bool)
    /// The config file isn't valid JSON (or isn't shaped like one). Veil won't touch it.
    case unreadable(String)
}

public struct ConnectError: LocalizedError, Equatable {
    public let message: String
    public init(_ m: String) { message = m }
    public var errorDescription: String? { message }
}

/// A client configured by a JSON file with an `mcpServers` object (Claude Desktop, Cursor).
public struct MCPConfigTarget: Sendable {
    public let name: String
    public let file: URL
    /// Any of these existing means the client is installed (app bundles, its settings folder).
    public let installMarkers: [URL]
    public let restartHint: String

    public init(name: String, file: URL, installMarkers: [URL], restartHint: String) {
        self.name = name; self.file = file; self.installMarkers = installMarkers; self.restartHint = restartHint
    }

    public static func claudeDesktop(home: URL, applications: [URL]) -> MCPConfigTarget {
        let dir = home.appendingPathComponent("Library/Application Support/Claude")
        return MCPConfigTarget(name: "Claude Desktop", file: dir.appendingPathComponent("claude_desktop_config.json"),
                               installMarkers: applications.map { $0.appendingPathComponent("Claude.app") } + [dir],
                               restartHint: "Quit and reopen Claude Desktop to pick it up.")
    }

    public static func cursor(home: URL, applications: [URL]) -> MCPConfigTarget {
        let dir = home.appendingPathComponent(".cursor")
        return MCPConfigTarget(name: "Cursor", file: dir.appendingPathComponent("mcp.json"),
                               installMarkers: applications.map { $0.appendingPathComponent("Cursor.app") } + [dir],
                               restartHint: "Restart Cursor (or reload its MCP servers) to pick it up.")
    }

    public var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: file.path) || installMarkers.contains { fm.fileExists(atPath: $0.path) }
    }

    public func status(command: String) -> ConnectStatus {
        guard isInstalled else { return .notInstalled }
        let data: Data
        do { data = try Data(contentsOf: file) } catch {
            return FileManager.default.fileExists(atPath: file.path) ? .unreadable("Veil can't read \(file.lastPathComponent).") : .notConnected
        }
        do {
            let root = try MCPConfigEditor.parse(data)
            return MCPConfigEditor.status(of: try MCPConfigEditor.servers(in: root)["veil"], command: command)
        } catch { return .unreadable((error as? ConnectError)?.message ?? "\(error)") }
    }

    public func plan(_ action: ConfigPlan.Action, command: String) throws -> ConfigPlan {
        try MCPConfigEditor.plan(action, file: file, command: command)
    }
}

/// What a config change will do, shown to the user before anything is written.
public struct ConfigPlan: Equatable, Sendable {
    public enum Action: String, Sendable { case add, fix, remove }
    public let action: Action
    public let file: URL
    /// The file as it was when planned (nil when it doesn't exist yet). Writing refuses if it changed since.
    public let original: Data?
    public let newContents: Data
    /// The `veil` entry before and after, pretty-printed (nil when absent).
    public let entryBefore: String?
    public let entryAfter: String?
    /// Other servers in the file, left exactly as they are.
    public let otherServers: [String]

    public var newText: String { String(decoding: newContents, as: UTF8.self) }
    public var createsFile: Bool { original == nil }
}

/// Merges, fixes and removes Veil's entry in an `mcpServers` JSON file without touching anything
/// else, after a timestamped backup. Refuses files that aren't valid JSON.
public enum MCPConfigEditor {
    public static let key = "veil"

    static func parse(_ data: Data) throws -> [String: Any] {
        if String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        let obj: Any
        do { obj = try JSONSerialization.jsonObject(with: data, options: []) } catch {
            throw ConnectError("This file isn't valid JSON, so Veil won't change it. Fix it by hand or paste the config yourself.")
        }
        guard let root = obj as? [String: Any] else { throw ConnectError("This file isn't a JSON object, so Veil won't change it.") }
        return root
    }

    static func servers(in root: [String: Any]) throws -> [String: Any] {
        guard let s = root["mcpServers"] else { return [:] }
        guard let dict = s as? [String: Any] else { throw ConnectError("\"mcpServers\" in this file isn't an object, so Veil won't change it.") }
        return dict
    }

    static func status(of entry: Any?, command: String) -> ConnectStatus {
        guard let entry else { return .notConnected }
        let e = entry as? [String: Any]
        guard let cmd = e?["command"] as? String else {
            return .otherPath((e?["url"] as? String) ?? "an entry without a command", exists: false)
        }
        if samePath(cmd, command) { return .connected }
        let expanded = (cmd as NSString).expandingTildeInPath
        return .otherPath(cmd, exists: FileManager.default.isExecutableFile(atPath: expanded))
    }

    static func samePath(_ a: String, _ b: String) -> Bool {
        func norm(_ p: String) -> String { URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path }
        return a == b || norm(a) == norm(b)
    }

    static func pretty(_ obj: Any) -> Data {
        let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return d + Data("\n".utf8)
    }

    static func entryText(_ entry: Any?) -> String? {
        guard let entry else { return nil }
        return String(decoding: pretty(["veil": entry]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func plan(_ action: ConfigPlan.Action, file: URL, command: String) throws -> ConfigPlan {
        let original = FileManager.default.fileExists(atPath: file.path) ? try Data(contentsOf: file) : nil
        var root = try original.map(parse) ?? [:]
        var servers = try servers(in: root)
        let before = servers[key]
        switch action {
        case .add, .fix: servers[key] = ["command": command]
        case .remove:
            guard before != nil else { throw ConnectError("Veil isn't in this file.") }
            servers[key] = nil
        }
        root["mcpServers"] = servers
        return ConfigPlan(action: action, file: file, original: original, newContents: pretty(root),
                          entryBefore: entryText(before), entryAfter: entryText(servers[key]),
                          otherServers: servers.keys.filter { $0 != key }.sorted())
    }

    /// Writes the plan: refuses if the file changed since it was planned, backs the old file up next
    /// to it, then replaces it atomically (through a symlink, to the real file). Returns the backup.
    @discardableResult
    public static func apply(_ plan: ConfigPlan, now: Date = Date()) throws -> URL? {
        let fm = FileManager.default
        let target = plan.file.resolvingSymlinksInPath()
        let current = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
        guard current == plan.original else { throw ConnectError("\(plan.file.lastPathComponent) changed since you reviewed it. Nothing was written; review it again.") }
        var backup: URL?
        var permissions: Any?
        if let current {
            permissions = try? fm.attributesOfItem(atPath: target.path)[.posixPermissions]
            let b = backupURL(for: target, now: now)
            try current.write(to: b, options: .withoutOverwriting)
            backup = b
        } else {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try plan.newContents.write(to: target, options: .atomic)
        if let permissions { try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
        return backup
    }

    static func backupURL(for file: URL, now: Date) -> URL {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyyMMdd-HHmmss"
        let base = file.lastPathComponent + ".veil-backup-" + f.string(from: now)
        var url = file.deletingLastPathComponent().appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = file.deletingLastPathComponent().appendingPathComponent("\(base)-\(n)"); n += 1
        }
        return url
    }
}

/// Claude Code is configured through its own CLI (`claude mcp add --scope user …`), never by
/// editing its files. Its status is read from `~/.claude.json` (read-only).
public struct ClaudeCodeConnector: Sendable {
    public typealias Runner = @Sendable (_ executable: URL, _ arguments: [String], _ environment: [String: String]) -> (status: Int32, output: String)
    /// The CLI path and, if the login shell reported one, its PATH (node usually lives there).
    public typealias Lookup = @Sendable () -> (cli: String?, path: String?)

    public let home: URL
    public let candidates: [String]
    public let shellLookup: Lookup
    public let run: Runner
    public let restartHint = "Start a new Claude Code session to pick it up."

    public init(home: URL, candidates: [String]? = nil, shellLookup: @escaping Lookup, run: @escaping Runner) {
        self.home = home
        self.candidates = candidates ?? [
            home.appendingPathComponent(".claude/local/claude").path, home.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude", "/usr/local/bin/claude",
            home.appendingPathComponent(".npm-global/bin/claude").path, home.appendingPathComponent(".bun/bin/claude").path,
        ]
        self.shellLookup = shellLookup; self.run = run
    }

    public var configFile: URL { home.appendingPathComponent(".claude.json") }

    /// Common install paths first, then a login-shell `command -v claude`.
    public func findCLI() -> (cli: URL, path: String?)? {
        let fm = FileManager.default
        let shell = shellLookup()
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return (URL(fileURLWithPath: hit), shell.path) }
        if let s = shell.cli, s.hasPrefix("/"), fm.isExecutableFile(atPath: s) { return (URL(fileURLWithPath: s), shell.path) }
        return nil
    }

    public static func addArguments(command: String) -> [String] { ["mcp", "add", "--scope", "user", "veil", "--", command] }
    public static let removeArguments = ["mcp", "remove", "--scope", "user", "veil"]

    /// What to show (and what to copy when the CLI isn't found).
    public static func commandLine(_ args: [String], cli: String = "claude") -> String {
        ([cli] + args).map(shellQuote).joined(separator: " ")
    }

    static func shellQuote(_ s: String) -> String {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./:=@%+,")
        if !s.isEmpty, s.unicodeScalars.allSatisfy(safe.contains) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The commands a change runs. Fix removes the old entry first.
    public static func commands(_ action: ConfigPlan.Action, command: String) -> [[String]] {
        switch action {
        case .add: return [addArguments(command: command)]
        case .fix: return [removeArguments, addArguments(command: command)]
        case .remove: return [removeArguments]
        }
    }

    public func status(command: String, cliFound: Bool) -> ConnectStatus {
        let data = try? Data(contentsOf: configFile)
        guard cliFound || data != nil else { return .notInstalled }
        guard let data, let root = try? MCPConfigEditor.parse(data), let servers = try? MCPConfigEditor.servers(in: root) else {
            return .notConnected
        }
        return MCPConfigEditor.status(of: servers["veil"], command: command)
    }

    /// Runs the CLI for this change. Throws with its output if any step fails.
    public func perform(_ action: ConfigPlan.Action, command: String, cli: URL, loginPath: String?) throws {
        var env = ProcessInfo.processInfo.environment
        // `claude` is a node script; GUI apps don't get the shell's PATH, so add it and the CLI's folder.
        let dirs: [String?] = [cli.deletingLastPathComponent().path, loginPath, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = dirs.compactMap { $0 }.joined(separator: ":")
        for args in Self.commands(action, command: command) {
            let r = run(cli, args, env)
            // Removing something that isn't there is fine when fixing.
            if r.status != 0 && !(action == .fix && args == Self.removeArguments) {
                throw ConnectError("`\(Self.commandLine(args))` failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))")
            }
        }
    }
}

/// Runs a process with a timeout and returns its exit status and combined output. Used for the
/// login-shell lookup and the Claude Code CLI; tests inject their own runner instead.
public enum ProcessRunner {
    public static func run(_ exe: URL, _ args: [String], env: [String: String]? = nil, timeout: TimeInterval = 20) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = exe; p.arguments = args
        if let env { p.environment = env }
        let out = Pipe()
        p.standardOutput = out; p.standardError = out; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "\(error.localizedDescription)") }
        let done = DispatchSemaphore(value: 0)
        let box = OutputBox()
        DispatchQueue.global().async { box.data = out.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: .now() + timeout) == .timedOut { p.terminate(); return (-1, "Timed out") }
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: box.data, as: UTF8.self))
    }

    /// `command -v claude` and `$PATH` from the user's login shell.
    public static func loginShellLookup(_ tool: String) -> (cli: String?, path: String?) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let r = run(URL(fileURLWithPath: shell), ["-l", "-c", "command -v \(tool); printf 'PATH=%s\\n' \"$PATH\""], timeout: 8)
        guard r.status == 0 || r.status == 1 else { return (nil, nil) }
        let lines = r.output.split(separator: "\n").map(String.init)
        let path = lines.last { $0.hasPrefix("PATH=") }.map { String($0.dropFirst(5)) }
        let cli = lines.first { $0.hasPrefix("/") && $0.hasSuffix("/\(tool)") }
        return (cli, path)
    }

    private final class OutputBox: @unchecked Sendable { var data = Data() }
}
