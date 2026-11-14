import Foundation
import Testing
@testable import VeilCore

/// One-click connect. Every path points into a temp folder that stands in for the home folder; the
/// real Claude, Cursor and Claude Code configs are never read or written, and the real `claude`
/// CLI is never run.
@Suite("One-click connect")
struct ConnectClientTests {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("veil-home-\(UUID().uuidString)")
    let relay = "/Volumes/NoSuchDisk/Veil.app/Contents/MacOS/veil-mcp"
    var apps: URL { home.appendingPathComponent("Applications") }
    var desktop: MCPConfigTarget { .claudeDesktop(home: home, applications: [apps]) }
    var cursor: MCPConfigTarget { .cursor(home: home, applications: [apps]) }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    func json(_ url: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }
    func backups(of url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".veil-backup-") }
    }
    func cleanup() { try? FileManager.default.removeItem(at: home) }

    @Test func pathsStayInsideTheInjectedHome() {
        #expect(desktop.file.path.hasPrefix(home.path))
        #expect(desktop.file.path.hasSuffix("Library/Application Support/Claude/claude_desktop_config.json"))
        #expect(cursor.file.path == home.appendingPathComponent(".cursor/mcp.json").path)
    }

    // MARK: Merging

    @Test func missingFileIsCreatedWithoutABackup() throws {
        defer { cleanup() }
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Cursor.app"), withIntermediateDirectories: true)
        let plan = try cursor.plan(.add, command: relay)
        #expect(plan.createsFile && plan.entryBefore == nil)
        #expect(plan.entryAfter?.contains(relay) == true)
        #expect(try MCPConfigEditor.apply(plan) == nil)
        let servers = try #require(try json(cursor.file)["mcpServers"] as? [String: Any])
        #expect((servers["veil"] as? [String: Any])?["command"] as? String == relay)
        #expect(cursor.status(command: relay) == .connected)
    }

    @Test func emptyFileIsTreatedAsEmptyObject() throws {
        defer { cleanup() }
        try write("  \n", to: desktop.file)
        let plan = try desktop.plan(.add, command: relay)
        try MCPConfigEditor.apply(plan)
        #expect(try json(desktop.file).keys.sorted() == ["mcpServers"])
        #expect(desktop.status(command: relay) == .connected)
        #expect(try backups(of: desktop.file).count == 1)
    }

    @Test func otherServersAndKeysAreLeftAlone() throws {
        defer { cleanup() }
        try write("""
        {"globalShortcut": "Cmd+Space", "mcpServers": {"files": {"command": "npx", "args": ["-y", "server-files", "/Users/x/Docs"], "env": {"TOKEN": "abc", "N": 3}}, "web": {"url": "https://example.com/mcp"}}, "flag": true, "ratio": 0.5}
        """, to: desktop.file)
        let plan = try desktop.plan(.add, command: relay)
        #expect(plan.otherServers == ["files", "web"])
        try MCPConfigEditor.apply(plan)
        let root = try json(desktop.file)
        #expect(root["globalShortcut"] as? String == "Cmd+Space")
        #expect(root["flag"] as? Bool == true)
        #expect(root["ratio"] as? Double == 0.5)
        let servers = try #require(root["mcpServers"] as? [String: Any])
        let files = try #require(servers["files"] as? [String: Any])
        #expect(files["args"] as? [String] == ["-y", "server-files", "/Users/x/Docs"])
        #expect((files["env"] as? [String: Any])?["N"] as? Int == 3)
        #expect((servers["web"] as? [String: Any])?["url"] as? String == "https://example.com/mcp")
        #expect(servers.count == 3)
        // Reasonable formatting: pretty-printed, slashes unescaped, trailing newline.
        let text = try String(contentsOf: desktop.file, encoding: .utf8)
        #expect(text.contains("\n  \"mcpServers\""))
        #expect(text.contains(relay))
        #expect(text.hasSuffix("}\n"))
    }

    @Test func invalidFileIsRefusedAndUntouched() throws {
        defer { cleanup() }
        let broken = "{\"mcpServers\": {\"files\": {\"command\": \"npx\",}}"
        try write(broken, to: cursor.file)
        #expect(throws: ConnectError.self) { try cursor.plan(.add, command: relay) }
        if case .unreadable(let why) = cursor.status(command: relay) { #expect(why.contains("isn't valid JSON")) }
        else { Issue.record("expected unreadable") }
        // A JSON array, or mcpServers that isn't an object, is refused too.
        try write("[1, 2]", to: desktop.file)
        #expect(throws: ConnectError.self) { try desktop.plan(.add, command: relay) }
        try write("{\"mcpServers\": [\"veil\"]}", to: desktop.file)
        #expect(throws: ConnectError.self) { try desktop.plan(.add, command: relay) }
        #expect(try String(contentsOf: cursor.file, encoding: .utf8) == broken)
        #expect(try backups(of: cursor.file).isEmpty)
    }

    @Test func backupHoldsTheOldFileAndNeverOverwrites() throws {
        defer { cleanup() }
        let original = "{\"mcpServers\": {\"files\": {\"command\": \"npx\"}}}"
        try write(original, to: desktop.file)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let b1 = try #require(try MCPConfigEditor.apply(try desktop.plan(.add, command: relay), now: now))
        #expect(b1.deletingLastPathComponent() == desktop.file.deletingLastPathComponent())
        #expect(b1.lastPathComponent.hasPrefix("claude_desktop_config.json.veil-backup-2027"))
        #expect(try String(contentsOf: b1, encoding: .utf8) == original)
        // A second change in the same second gets its own backup.
        let b2 = try #require(try MCPConfigEditor.apply(try desktop.plan(.remove, command: relay), now: now))
        #expect(b2 != b1)
        #expect(try backups(of: desktop.file).count == 2)
        #expect(try String(contentsOf: b1, encoding: .utf8) == original)
    }

    @Test func refusesIfTheFileChangedAfterReview() throws {
        defer { cleanup() }
        try write("{}", to: cursor.file)
        let plan = try cursor.plan(.add, command: relay)
        try write("{\"mcpServers\": {\"new\": {\"command\": \"x\"}}}", to: cursor.file)
        #expect(throws: ConnectError.self) { try MCPConfigEditor.apply(plan) }
        #expect(try json(cursor.file)["mcpServers"] as? [String: [String: String]] == ["new": ["command": "x"]])
    }

    @Test func writesThroughASymlinkToTheRealFile() throws {
        defer { cleanup() }
        let real = home.appendingPathComponent("dotfiles/mcp.json")
        try write("{}", to: real)
        try FileManager.default.createDirectory(at: cursor.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: cursor.file, withDestinationURL: real)
        try MCPConfigEditor.apply(try cursor.plan(.add, command: relay))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: cursor.file.path) == real.path)
        #expect(cursor.status(command: relay) == .connected)
    }

    @Test func fixAndRemove() throws {
        defer { cleanup() }
        try write("{\"mcpServers\": {\"veil\": {\"command\": \"/old/Veil.app/Contents/MacOS/veil-mcp\"}, \"files\": {\"command\": \"npx\"}}}", to: desktop.file)
        let fix = try desktop.plan(.fix, command: relay)
        #expect(fix.entryBefore?.contains("/old/Veil.app") == true)
        #expect(fix.entryAfter?.contains(relay) == true)
        try MCPConfigEditor.apply(fix)
        #expect(desktop.status(command: relay) == .connected)
        try MCPConfigEditor.apply(try desktop.plan(.remove, command: relay))
        #expect(desktop.status(command: relay) == .notConnected)
        let servers = try #require(try json(desktop.file)["mcpServers"] as? [String: Any])
        #expect(servers.keys.sorted() == ["files"])
        #expect(throws: ConnectError.self) { try desktop.plan(.remove, command: relay) }
    }

    // MARK: Status

    @Test func statusStates() throws {
        defer { cleanup() }
        #expect(desktop.status(command: relay) == .notInstalled)
        try FileManager.default.createDirectory(at: apps.appendingPathComponent("Claude.app"), withIntermediateDirectories: true)
        #expect(desktop.status(command: relay) == .notConnected)
        try write("{\"mcpServers\": {}}", to: desktop.file)
        #expect(desktop.status(command: relay) == .notConnected)
        try write("{\"mcpServers\": {\"veil\": {\"command\": \"\(relay)\"}}}", to: desktop.file)
        #expect(desktop.status(command: relay) == .connected)
        // Pointing at a copy that's gone.
        try write("{\"mcpServers\": {\"veil\": {\"command\": \"/gone/veil-mcp\"}}}", to: desktop.file)
        #expect(desktop.status(command: relay) == .otherPath("/gone/veil-mcp", exists: false))
        // Pointing at a different copy that exists.
        let other = home.appendingPathComponent("Other/veil-mcp")
        try write("#!/bin/sh\n", to: other)
        chmod(other.path, 0o755)
        try write("{\"mcpServers\": {\"veil\": {\"command\": \"\(other.path)\"}}}", to: desktop.file)
        #expect(desktop.status(command: relay) == .otherPath(other.path, exists: true))
        // The same file through a different spelling counts as connected.
        #expect(desktop.status(command: home.appendingPathComponent("Other/../Other/veil-mcp").path) == .connected)
        try write("{oops", to: desktop.file)
        guard case .unreadable = desktop.status(command: relay) else { Issue.record("expected unreadable"); return }
    }

    // MARK: Claude Code

    final class Recorder: @unchecked Sendable {
        var calls: [(String, [String], String?)] = []
        var status: Int32 = 0
    }

    func claudeCode(_ r: Recorder, candidates: [String] = [], shell: String? = nil) -> ClaudeCodeConnector {
        ClaudeCodeConnector(home: home, candidates: candidates, shellLookup: { (shell, "/Users/x/.nvm/versions/node/v22/bin") },
                            run: { exe, args, env in r.calls.append((exe.path, args, env["PATH"])); return (r.status, r.status == 0 ? "ok" : "boom") })
    }

    @Test func claudeCodeCommandLine() {
        #expect(ClaudeCodeConnector.addArguments(command: relay) == ["mcp", "add", "--scope", "user", "veil", "--", relay])
        #expect(ClaudeCodeConnector.commandLine(ClaudeCodeConnector.addArguments(command: relay))
                == "claude mcp add --scope user veil -- /Volumes/NoSuchDisk/Veil.app/Contents/MacOS/veil-mcp")
        let spaced = "/Users/a b/Applications/Veil's Copy.app/Contents/MacOS/veil-mcp"
        #expect(ClaudeCodeConnector.commandLine(ClaudeCodeConnector.addArguments(command: spaced))
                == "claude mcp add --scope user veil -- '/Users/a b/Applications/Veil'\\''s Copy.app/Contents/MacOS/veil-mcp'")
        #expect(ClaudeCodeConnector.commandLine(ClaudeCodeConnector.removeArguments) == "claude mcp remove --scope user veil")
        #expect(ClaudeCodeConnector.commands(.fix, command: relay) == [ClaudeCodeConnector.removeArguments, ClaudeCodeConnector.addArguments(command: relay)])
    }

    @Test func claudeCodeIsFoundAndRunWithTheRightArguments() throws {
        defer { cleanup() }
        let r = Recorder()
        let fake = home.appendingPathComponent("bin/claude")
        try write("#!/bin/sh\nexit 1\n", to: fake)   // never run: the recorder stands in for it
        chmod(fake.path, 0o755)
        // Not at a common path, found through the login shell.
        let cc = claudeCode(r, candidates: [home.appendingPathComponent("nope/claude").path], shell: fake.path)
        let found = try #require(cc.findCLI())
        #expect(found.cli.path == fake.path)
        try cc.perform(.add, command: relay, cli: found.cli, loginPath: found.path)
        #expect(r.calls.count == 1)
        #expect(r.calls[0].0 == fake.path)
        #expect(r.calls[0].1 == ["mcp", "add", "--scope", "user", "veil", "--", relay])
        #expect(r.calls[0].2?.hasPrefix(fake.deletingLastPathComponent().path + ":/Users/x/.nvm/versions/node/v22/bin") == true)

        r.status = 1
        #expect(throws: ConnectError.self) { try cc.perform(.add, command: relay, cli: found.cli, loginPath: nil) }
    }

    @Test func claudeCodeNotFound() {
        let r = Recorder()
        #expect(claudeCode(r, candidates: ["/nonexistent/claude"], shell: nil).findCLI() == nil)
        #expect(claudeCode(r, candidates: [], shell: "claude not found").findCLI() == nil)
        #expect(r.calls.isEmpty)
    }

    @Test func claudeCodeStatusFromItsConfig() throws {
        defer { cleanup() }
        let cc = claudeCode(Recorder())
        #expect(cc.status(command: relay, cliFound: false) == .notInstalled)
        #expect(cc.status(command: relay, cliFound: true) == .notConnected)
        try write("{\"projects\": {}, \"mcpServers\": {\"veil\": {\"type\": \"stdio\", \"command\": \"\(relay)\", \"args\": []}}}", to: cc.configFile)
        #expect(cc.status(command: relay, cliFound: true) == .connected)
        #expect(cc.status(command: "/elsewhere/veil-mcp", cliFound: true) == .otherPath(relay, exists: false))
    }
}
