import Foundation
import Testing
@testable import VeilCore

/// Reading Full Disk Access grants from a fake TCC.db built in the test. The real TCC databases
/// are never opened here.
@Suite("Full Disk Access list")
struct FullDiskAccessTests {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("veil-tcc-\(UUID().uuidString)")

    func build(_ rows: [DemoData.TCCRow], legacy: Bool = false, name: String = "TCC.db") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try DemoData.buildTCC(at: url, rows: rows, legacy: legacy)
        return url
    }

    @Test func listsAllowedGrantsWithNamesAndHighlightsAssistantHosts() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try build(DemoData.demoFullDiskAccess)
        let list = try #require(FullDiskAccessList.read(system: db, user: nil, resolveName: { DemoData.demoAppNames[$0] }))
        #expect(list.map(\.name) == ["Goose", "iTerm", "node", "PhotoSync"])
        #expect(list.map(\.kind) == [.ai, .terminal, .commandLine, .other])
        #expect(list.filter(\.isLikelyAssistantHost).count == 3)
        // Veil itself, other services and denied rows are left out.
        #expect(!list.contains { $0.client == "io.github.benlittlle.veil" })
        #expect(!list.contains { $0.client == "com.anthropic.claudefordesktop" })
        #expect(!list.contains { $0.client == "com.apple.Terminal" })
    }

    @Test func olderLayoutWithAllowedColumnWorks() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try build([.init("com.todesktop.230313mzl4w4u92"), .init("com.apple.Terminal", allowed: false)], legacy: true)
        let list = try #require(FullDiskAccessList.read(system: db, user: nil))
        #expect(list.map(\.name) == ["Cursor"])
        #expect(list.first?.kind == .ai)
    }

    @Test func userDatabaseRowsAreAddedAndDeduplicated() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let system = try build([.init("com.apple.Terminal")])
        let user = try build([.init("com.apple.Terminal"), .init("/Applications/Zed.app/Contents/MacOS/zed", path: true)], name: "user.db")
        let list = try #require(FullDiskAccessList.read(system: system, user: user))
        #expect(list.map(\.name) == ["Terminal", "Zed"])
    }

    @Test func unreadableOrUnknownLayoutHidesTheList() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(FullDiskAccessList.read(system: dir.appendingPathComponent("missing.db"), user: nil) == nil)
        let odd = dir.appendingPathComponent("odd.db")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = try SQLiteDB(path: odd.path, readOnly: false)
        try db.query("CREATE TABLE access (service TEXT, client TEXT, something_new INTEGER)")
        #expect(FullDiskAccessList.read(system: odd, user: nil) == nil)
        try Data("not sqlite".utf8).write(to: dir.appendingPathComponent("junk.db"))
        #expect(FullDiskAccessList.read(system: dir.appendingPathComponent("junk.db"), user: nil) == nil)
        // A broken user database doesn't hide the system list.
        let system = try build([.init("com.apple.Terminal")])
        #expect(FullDiskAccessList.read(system: system, user: odd)?.map(\.name) == ["Terminal"])
    }

    @Test func readingNeverChangesTheDatabase() throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let db = try build(DemoData.demoFullDiskAccess)
        let before = try Data(contentsOf: db)
        let modified = try FileManager.default.attributesOfItem(atPath: db.path)[.modificationDate] as? Date
        _ = FullDiskAccessList.read(system: db, user: nil)
        #expect(try Data(contentsOf: db) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: db.path)[.modificationDate] as? Date == modified)
    }

    @Test func kindsFromNamesAndPaths() {
        #expect(FullDiskAccessList.kind(client: "/usr/local/bin/claude", isPath: true, name: "claude") == .ai)
        #expect(FullDiskAccessList.kind(client: "/usr/libexec/sshd-keygen-wrapper", isPath: true, name: "Remote Login (SSH)") == .terminal)
        #expect(FullDiskAccessList.kind(client: "com.jetbrains.intellij", isPath: false, name: "IntelliJ IDEA") == .editor)
        #expect(FullDiskAccessList.kind(client: "com.example.backup", isPath: false, name: "Backup") == .other)
    }
}
