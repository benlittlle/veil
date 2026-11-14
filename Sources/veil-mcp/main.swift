// veil-mcp: the command an MCP client (Claude Desktop, Cursor, your own agent) launches.
//
// It is only a pipe. It relays newline-delimited JSON-RPC between stdin/stdout and the
// Veil app's private Unix socket. It never reads chat.db, so the assistant that
// launches it needs no Full Disk Access, and all filtering happens inside the app.
//
// One check, no reading: macOS attributes file access to the app that launched this relay,
// so on startup it asks the kernel whether chat.db *could* be opened (open, then close at
// once; not a single byte is read). If it could, the assistant's own app has Full Disk
// Access and can skip Veil entirely. The relay tells Veil that one yes/no in a hello line
// (a JSON-RPC notification, `veil/relayHello`) before relaying anything, and Veil warns
// the user. An older Veil ignores the line; the assistant never sees it.

import Foundation

let bundleID = "io.github.benlittlle.veil"
/// The Veil.app this relay ships inside, if any, so the right copy is launched.
let enclosingApp: String? = {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
    let suffix = "/Contents/MacOS/veil-mcp"
    return exe.hasSuffix(suffix) ? String(exe.dropLast(suffix.count)) : nil
}()
let env = ProcessInfo.processInfo.environment
let socketPath = env["VEIL_SOCKET"] ?? NSHomeDirectory() + "/Library/Application Support/Veil/mcp.sock"
/// Overridable so tests can point the check at a fixture instead of the real database.
let chatDBPath = env["VEIL_CHAT_DB"] ?? NSHomeDirectory() + "/Library/Messages/chat.db"

/// Could the app that launched us open chat.db? Opens and immediately closes it; never reads.
func chatDBOpenable() -> Bool {
    let f = open(chatDBPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
    guard f >= 0 else { return false }
    close(f)
    return true
}
let chatDBReadable = chatDBOpenable()

func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(socketPath.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
    let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    if rc == 0 { return fd }
    close(fd); return nil
}

func write(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count { let n = Darwin.write(fd, raw.baseAddress! + off, raw.count - off); if n <= 0 { return false }; off += n }
        return true
    }
}

var fd = connectSocket()
if fd == nil && env["VEIL_NO_LAUNCH"] == nil {
    // Try to start the app in the background, then wait for it.
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = enclosingApp.map { ["-g", $0] } ?? ["-g", "-b", bundleID]
    try? open.run(); open.waitUntilExit()
    for _ in 0..<30 where fd == nil { usleep(500_000); fd = connectSocket() }
}

guard let sock = fd else {
    // Answer every request with a clear error so the assistant can tell the user what's wrong.
    FileHandle.standardError.write(Data("veil-mcp: Veil isn't running (\(socketPath))\n".utf8))
    while let line = readLine() {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let id = obj["id"] else { continue }
        let reply: [String: Any] = ["jsonrpc": "2.0", "id": id,
                                    "error": ["code": -32000, "message": "Veil isn't running. Ask the user to open the Veil app."]]
        if let d = try? JSONSerialization.data(withJSONObject: reply) { _ = write(STDOUT_FILENO, d + Data("\n".utf8)) }
    }
    exit(1)
}

var nosig: Int32 = 1
setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
signal(SIGPIPE, SIG_IGN)

// The hello goes first, before anything from the assistant (see the header comment).
let hello = #"{"jsonrpc":"2.0","method":"veil/relayHello","params":{"chatDbReadable":\#(chatDBReadable),"relayVersion":1}}"# + "\n"
_ = write(sock, Data(hello.utf8))

// stdin -> socket
Thread.detachNewThread {
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(STDIN_FILENO, &buf, buf.count)
        if n <= 0 || !write(sock, Data(buf[0..<n])) { shutdown(sock, SHUT_WR); return }
    }
}

// socket -> stdout
var buf = [UInt8](repeating: 0, count: 65536)
while true {
    let n = read(sock, &buf, buf.count)
    if n <= 0 || !write(STDOUT_FILENO, Data(buf[0..<n])) { break }
}
exit(0)
