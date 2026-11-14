import Foundation

/// Names the app used before it was called Veil. Only the migration below uses them, to find
/// an existing install's data. Nothing else should refer to the old name.
public enum Legacy {
    public static let name = "MessagesGate"
    public static let bundleID = "local.messagesgate.MessagesGate"
    public static let supportFolder = "MessagesGate"
    public static let permissionsKeyService = "MessagesGate permissions key"
    public static let webhookKeyService = "MessagesGate webhook key"
}

/// What happened when Veil looked for an older install. Contains no data, only outcomes.
public struct MigrationReport: Equatable, Sendable {
    public enum Folder: Equatable, Sendable {
        case notNeeded             // Veil's folder already has its permissions
        case nothingToMove         // no older install
        case moved(items: Int)
        case failed(String)
    }
    public enum Secret: Equatable, Sendable {
        case notNeeded             // Veil already has its own, or nothing moved this launch
        case notFound              // the older install never stored one
        case migrated
        case unavailable(String)   // there, but couldn't be read without the user's approval (or at all)
    }
    public var folder = Folder.nothingToMove
    public var settingsCopied = 0
    public var permissionsKey = Secret.notNeeded
    public var webhookKey = Secret.notNeeded
    public init() {}

    public var summary: String {
        "folder=\(folder) settings=\(settingsCopied) permissionsKey=\(permissionsKey) webhookKey=\(webhookKey)"
    }
}

/// Moves an older install (Application Support folder, settings, Keychain items) over to Veil.
///
/// Fails closed: Keychain items are read without prompts. If the permissions key can't be read,
/// the moved permissions file has no key to verify against, so `PermissionStore` treats every
/// chat as off and says so until the user imports the key themselves or starts fresh.
public struct LegacyMigrator {
    public static let settingsMarker = "migratedFromLegacyName"

    public var oldDir: URL
    public var newDir: URL
    /// The older install's settings domain (its persistent domain), if any.
    public var oldSettings: [String: Any]?
    public var newSettings: UserDefaults
    public var oldPermissionsKey: SecretStore
    public var newPermissionsKey: SecretStore
    public var oldWebhookKey: StringSecretStore
    public var newWebhookKey: StringSecretStore

    public init(oldDir: URL, newDir: URL, oldSettings: [String: Any]?, newSettings: UserDefaults,
                oldPermissionsKey: SecretStore, newPermissionsKey: SecretStore,
                oldWebhookKey: StringSecretStore, newWebhookKey: StringSecretStore) {
        self.oldDir = oldDir; self.newDir = newDir
        self.oldSettings = oldSettings; self.newSettings = newSettings
        self.oldPermissionsKey = oldPermissionsKey; self.newPermissionsKey = newPermissionsKey
        self.oldWebhookKey = oldWebhookKey; self.newWebhookKey = newWebhookKey
    }

    public func run() -> MigrationReport {
        var r = MigrationReport()
        r.settingsCopied = copySettings()
        r.folder = moveFolder()
        // Keys only follow a folder that moved just now. An old key is never used to vouch for an
        // old permissions file that turns up later, so it can't be used to roll settings back.
        if case .moved = r.folder {
            r.permissionsKey = Self.copyKey(from: oldPermissionsKey, to: newPermissionsKey)
            r.webhookKey = Self.copyString(from: oldWebhookKey, to: newWebhookKey)
        }
        return r
    }

    /// Copies the older install's settings once. Never overwrites a setting Veil already has.
    func copySettings() -> Int {
        guard !newSettings.bool(forKey: Self.settingsMarker) else { return 0 }
        var n = 0
        for (k, v) in oldSettings ?? [:] where newSettings.object(forKey: k) == nil {
            newSettings.set(v, forKey: k); n += 1
        }
        newSettings.set(true, forKey: Self.settingsMarker)
        return n
    }

    /// Moves everything from the old folder into the new one. `permissions.json` moves last, so a
    /// move that stops halfway is simply retried on the next launch.
    func moveFolder() -> MigrationReport.Folder {
        let fm = FileManager.default
        let permissions = "permissions.json"
        guard fm.fileExists(atPath: oldDir.path) else { return .nothingToMove }
        if fm.fileExists(atPath: newDir.appendingPathComponent(permissions).path) { return .notNeeded }
        do {
            try fm.createDirectory(at: newDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let names = try fm.contentsOfDirectory(atPath: oldDir.path)
                .filter { $0 != "mcp.sock" }                       // the old app's socket; Veil makes its own
                .sorted { ($0 == permissions ? 1 : 0, $0) < ($1 == permissions ? 1 : 0, $1) }
            var moved = 0
            for name in names {
                let dst = newDir.appendingPathComponent(name)
                if fm.fileExists(atPath: dst.path) { continue }      // never overwrite anything Veil wrote
                try fm.moveItem(at: oldDir.appendingPathComponent(name), to: dst)
                moved += 1
            }
            try? fm.removeItem(at: oldDir.appendingPathComponent("mcp.sock"))
            if (try? fm.contentsOfDirectory(atPath: oldDir.path))?.isEmpty == true { try? fm.removeItem(at: oldDir) }
            return .moved(items: moved)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Copies the permissions signing key (and its generation counter) if Veil has none yet.
    public static func copyKey(from old: SecretStore, to new: SecretStore) -> MigrationReport.Secret {
        do { if try new.load() != nil { return .notNeeded } } catch { return .unavailable(error.localizedDescription) }
        do {
            guard let (key, generation) = try old.load() else { return .notFound }
            try new.save(key: key, generation: generation)
            return .migrated
        } catch { return .unavailable(error.localizedDescription) }
    }

    /// Copies a secret string (the webhook key) if Veil has none yet. The value is never logged.
    public static func copyString(from old: StringSecretStore, to new: StringSecretStore) -> MigrationReport.Secret {
        do { if let v = try new.load(), !v.isEmpty { return .notNeeded } } catch { return .unavailable(error.localizedDescription) }
        do {
            guard let v = try old.load(), !v.isEmpty else { return .notFound }
            try new.write(v)
            return .migrated
        } catch { return .unavailable(error.localizedDescription) }
    }
}
