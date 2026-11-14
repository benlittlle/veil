import Foundation
import Testing
@testable import VeilCore

/// Moving an install from before the rename. Temp folders, throwaway settings domains and
/// in-memory key stores only; nothing here touches the real Keychain items or Messages data.
@Suite("Migration from the old name")
struct MigrationTests {
    /// A Keychain item that exists but can't be read without the user's approval.
    final class LockedSecrets: SecretStore {
        struct NeedsApproval: Error {}
        func load() throws -> (Data, UInt64)? { throw NeedsApproval() }
        func save(key: Data, generation: UInt64) throws { throw NeedsApproval() }
    }
    final class LockedString: StringSecretStore {
        func load() throws -> String? { throw LockedSecrets.NeedsApproval() }
        func write(_ value: String) throws { throw LockedSecrets.NeedsApproval() }
    }

    /// An old install: a signed permissions file, logs, settings and Keychain items.
    final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("veil-migration-\(UUID().uuidString)")
        var oldDir: URL { root.appendingPathComponent(Legacy.supportFolder) }
        var newDir: URL { root.appendingPathComponent("Veil") }
        let oldKey = MemorySecretStore(), newKey = MemorySecretStore()
        let oldWebhook = MemoryStringStore("old-webhook-secret"), newWebhook = MemoryStringStore()
        let suite = "veil-migration-tests-\(UUID().uuidString)"
        lazy var newSettings = UserDefaults(suiteName: suite)!
        var oldSettings: [String: Any] = ["accent": "Ocean", "surface": "Neutral", "appearance": "Dark",
                                          "webhookEnabled": true, "webhookURL": "https://example.invalid/hook", "assistantName": "Assistant"]

        init(access: [String: ChatAccess] = ["chat-a": ChatAccess(read: true), "chat-b": ChatAccess(activity: true, filtered: true)]) throws {
            try FileManager.default.createDirectory(at: oldDir, withIntermediateDirectories: true)
            let store = PermissionStore(url: oldDir.appendingPathComponent("permissions.json"), secrets: oldKey)
            for (id, a) in access { try store.update { $0.chats[id] = a } }
            try store.update { $0.markReviewed(["chat-a", "chat-b"]) }
            for name in ["access-log.jsonl", "webhook-log.jsonl", "auto-sent.jsonl"] {
                try Data("{}\n".utf8).write(to: oldDir.appendingPathComponent(name))
            }
            try FileManager.default.createDirectory(at: oldDir.appendingPathComponent("cache"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: oldDir.appendingPathComponent("cache/filter.bin"))
            try Data().write(to: oldDir.appendingPathComponent("mcp.sock"))   // stale socket from the old app
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        func migrator(oldKey: SecretStore? = nil, oldWebhook: StringSecretStore? = nil) -> LegacyMigrator {
            LegacyMigrator(oldDir: oldDir, newDir: newDir, oldSettings: oldSettings, newSettings: newSettings,
                           oldPermissionsKey: oldKey ?? self.oldKey, newPermissionsKey: newKey,
                           oldWebhookKey: oldWebhook ?? self.oldWebhook, newWebhookKey: newWebhook)
        }

        func openNew() -> PermissionStore { PermissionStore(url: newDir.appendingPathComponent("permissions.json"), secrets: newKey) }
    }

    @Test func movesEverythingAndPermissionsStillVerify() throws {
        let f = try Fixture()
        let before = PermissionStore(url: f.oldDir.appendingPathComponent("permissions.json"), secrets: f.oldKey).state
        let report = f.migrator().run()
        #expect(report.folder == .moved(items: 5))
        #expect(report.permissionsKey == .migrated)
        #expect(report.webhookKey == .migrated)

        let fm = FileManager.default
        for name in ["permissions.json", "access-log.jsonl", "webhook-log.jsonl", "auto-sent.jsonl", "cache/filter.bin"] {
            #expect(fm.fileExists(atPath: f.newDir.appendingPathComponent(name).path), "\(name) should move")
        }
        #expect(!fm.fileExists(atPath: f.newDir.appendingPathComponent("mcp.sock").path))
        #expect(!fm.fileExists(atPath: f.oldDir.path))   // nothing left behind

        let store = f.openNew()
        #expect(store.integrity == .ok)
        #expect(!store.signingKeyMissing)
        #expect(store.state == before)
        #expect(store.state.access("chat-a").read)
        #expect(store.state.access("chat-b").activity && store.state.access("chat-b").filtered)
        try store.update { $0.chats["chat-c"] = ChatAccess(draft: true) }   // and it keeps working
        #expect(f.openNew().integrity == .ok)
        #expect(f.newWebhook.value == "old-webhook-secret")
    }

    @Test func copiesSettingsOnceWithoutOverwriting() throws {
        let f = try Fixture()
        f.newSettings.set("Plum", forKey: "accent")   // Veil already has its own choice
        let report = f.migrator().run()
        #expect(report.settingsCopied == 5)
        #expect(f.newSettings.string(forKey: "accent") == "Plum")
        #expect(f.newSettings.string(forKey: "surface") == "Neutral")
        #expect(f.newSettings.string(forKey: "appearance") == "Dark")
        #expect(f.newSettings.bool(forKey: "webhookEnabled"))
        #expect(f.newSettings.string(forKey: "webhookURL") == "https://example.invalid/hook")
        // Later launches never copy again, even if the old settings change.
        f.newSettings.removeObject(forKey: "surface")
        f.oldSettings["surface"] = "Warm"
        #expect(f.migrator().run().settingsCopied == 0)
        #expect(f.newSettings.string(forKey: "surface") == nil)
    }

    @Test func unreadableKeyFailsClosedAndSaysSo() throws {
        let f = try Fixture()
        let report = f.migrator(oldKey: LockedSecrets(), oldWebhook: LockedString()).run()
        guard case .moved = report.folder else { Issue.record("folder should still move"); return }
        guard case .unavailable = report.permissionsKey else { Issue.record("key should be unavailable"); return }
        guard case .unavailable = report.webhookKey else { Issue.record("webhook key should be unavailable"); return }
        #expect(f.newKey.stored == nil)
        #expect(f.newWebhook.value == nil)

        let store = f.openNew()
        guard case .tampered(let why) = store.integrity else { Issue.record("must fail closed"); return }
        #expect(why.contains("Keychain"))
        #expect(store.signingKeyMissing)
        #expect(store.state == PermissionState())                 // everything off
        #expect(store.state.access("chat-a") == .none)
        #expect(throws: (any Error).self) { try store.update { $0.chats["chat-a"] = ChatAccess(read: true) } }   // can't re-sign without a key
        #expect(f.newKey.stored == nil)                           // and didn't quietly make one

        // The assistant gets nothing while locked.
        let gate = Gate(permissions: store, log: AccessLog(url: nil), contacts: StaticContacts([:]), sender: RecordingSender(),
                        openStore: { throw NSError(domain: "unused", code: 1) })
        #expect(gate.call(tool: "list_chats", arguments: [:], client: "t").isError)

        // Relaunching doesn't change that.
        let again = f.openNew()
        #expect(again.signingKeyMissing)
        #expect(again.state == PermissionState())
    }

    @Test func startingFreshAfterAMissingKeyWorks() throws {
        let f = try Fixture()
        _ = f.migrator(oldKey: LockedSecrets()).run()
        let store = f.openNew()
        try store.reset()
        #expect(store.integrity == .ok)
        #expect(!store.signingKeyMissing)
        #expect(store.state.chats.isEmpty)
        #expect(f.newKey.stored != nil)
        let relaunched = f.openNew()
        #expect(relaunched.integrity == .ok)
        #expect(relaunched.state.chats.isEmpty)
    }

    @Test func importingTheKeyLaterRestoresSettings() throws {
        let f = try Fixture()
        _ = f.migrator(oldKey: LockedSecrets()).run()
        let store = f.openNew()
        #expect(store.signingKeyMissing)
        // The user allows the import: the old key (with its generation) is copied, then the file re-checked.
        #expect(LegacyMigrator.copyKey(from: f.oldKey, to: f.newKey) == .migrated)
        store.reload()
        #expect(store.integrity == .ok)
        #expect(store.state.access("chat-a").read)
        // A second import is a no-op and never replaces Veil's own key.
        #expect(LegacyMigrator.copyKey(from: MemorySecretStore(), to: f.newKey) == .notNeeded)
    }

    @Test func doesNothingOnceVeilHasItsOwnPermissions() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.newDir, withIntermediateDirectories: true)
        let mine = PermissionStore(url: f.newDir.appendingPathComponent("permissions.json"), secrets: f.newKey)
        try mine.update { $0.chats["mine"] = ChatAccess(read: true) }
        let keyBefore = f.newKey.stored?.0
        let report = f.migrator().run()
        #expect(report.folder == .notNeeded)
        #expect(report.permissionsKey == .notNeeded)
        #expect(f.newKey.stored?.0 == keyBefore)
        #expect(FileManager.default.fileExists(atPath: f.oldDir.appendingPathComponent("permissions.json").path))   // old left alone
        #expect(f.openNew().state.access("mine").read)
    }

    /// An old key never vouches for an old permissions file that turns up after the move.
    @Test func keysOnlyFollowAFolderMovedThisLaunch() throws {
        let f = try Fixture()
        try FileManager.default.removeItem(at: f.oldDir)
        let report = f.migrator().run()
        #expect(report.folder == .nothingToMove)
        #expect(report.permissionsKey == .notNeeded)
        #expect(report.webhookKey == .notNeeded)
        #expect(f.newKey.stored == nil && f.newWebhook.value == nil)
    }

    @Test func neverOverwritesFilesVeilAlreadyWrote() throws {
        let f = try Fixture()
        try FileManager.default.createDirectory(at: f.newDir, withIntermediateDirectories: true)
        try Data("veil's own log\n".utf8).write(to: f.newDir.appendingPathComponent("access-log.jsonl"))
        let report = f.migrator().run()
        #expect(report.folder == .moved(items: 4))
        #expect(try String(contentsOf: f.newDir.appendingPathComponent("access-log.jsonl"), encoding: .utf8) == "veil's own log\n")
        #expect(FileManager.default.fileExists(atPath: f.oldDir.appendingPathComponent("access-log.jsonl").path))   // kept, not lost
        #expect(f.openNew().integrity == .ok)
    }

    @Test func missingKeyWithAnExistingFileFailsClosed() throws {
        // Not just migration: a Keychain that lost its key must never look like a first run.
        let h = try Harness()
        let reloaded = PermissionStore(url: h.permissionsURL, secrets: MemorySecretStore())
        guard case .tampered = reloaded.integrity else { Issue.record("should fail closed"); return }
        #expect(reloaded.state.access(ID.mom) == .none)
    }

    @Test func noPromptKeychainReadOfMissingItemIsQuiet() throws {
        let service = "veil-test-missing-\(UUID().uuidString)"
        #expect(try KeychainSecretStore(service: service, allowUI: false).load() == nil)
        #expect(!KeychainSecretStore(service: service, allowUI: false).exists())
        #expect(try KeychainString(service: service, allowUI: false).load() == nil)
    }
}
