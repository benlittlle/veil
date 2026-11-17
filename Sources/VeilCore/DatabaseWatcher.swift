import Foundation

/// Says when chat.db may have changed: kernel file events (kqueue) on the database and its
/// write-ahead log, where Messages appends new rows, plus its folder, so the log is picked up again
/// when it's created or removed. Events are coalesced over `latency`. It only wakes the readers:
/// what changed is always read from the database itself, through the usual checks. Readers keep a
/// slow timer of their own in case an event is missed, so a lost event only delays things.
public final class DatabaseWatcher {
    private let folder: String
    private let files: [String]
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "Veil.dbwatch", qos: .utility)
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var running = false
    private var firing = false
    private var handlers: [() -> Void] = []

    public init(databasePath: String, latency: TimeInterval = 1) {
        let url = URL(fileURLWithPath: databasePath)
        folder = url.deletingLastPathComponent().path
        // Not the -shm file: readers write to it too, so it changes when nothing new arrived.
        files = [url.path, url.path + "-wal"]
        self.latency = latency
    }

    deinit { for s in sources.values { s.cancel() } }

    /// Called on a background queue after a change. Add handlers before `start`.
    public func onChange(_ handler: @escaping () -> Void) { queue.sync { handlers.append(handler) } }

    /// Returns false if nothing could be watched (e.g. no Full Disk Access yet); readers then rely
    /// on their fallback timers. Files that appear later are picked up through the folder. Safe to call
    /// again: it watches whatever it couldn't before (say, once Full Disk Access has been granted).
    @discardableResult
    public func start() -> Bool {
        queue.sync {
            running = true
            arm()
            return !sources.isEmpty
        }
    }

    public func stop() {
        queue.sync {
            running = false
            for s in sources.values { s.cancel() }
            sources = [:]
        }
    }

    /// On `queue`: watches whichever of the folder and files exist and aren't watched yet.
    private func arm() {
        guard running else { return }
        watch(folder, [.write]) { [weak self] _ in self?.arm(); self?.changed() }
        for f in files {
            watch(f, [.write, .extend, .delete, .rename, .revoke]) { [weak self] event in
                guard let self else { return }
                if !event.isDisjoint(with: [.delete, .rename, .revoke]) { self.unwatch(f); self.arm() }
                self.changed()
            }
        }
    }

    private func watch(_ path: String, _ mask: DispatchSource.FileSystemEvent, _ handler: @escaping (DispatchSource.FileSystemEvent) -> Void) {
        guard sources[path] == nil else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: mask, queue: queue)
        s.setEventHandler { [weak s] in if let s { handler(s.data) } }
        s.setCancelHandler { close(fd) }
        sources[path] = s
        s.resume()
    }

    private func unwatch(_ path: String) { sources.removeValue(forKey: path)?.cancel() }

    /// Coalesces a burst of writes into one call, `latency` after the first.
    private func changed() {
        guard running, !firing else { return }
        firing = true
        queue.asyncAfter(deadline: .now() + latency) { [self] in
            firing = false
            guard running else { return }
            handlers.forEach { $0() }
        }
    }
}
