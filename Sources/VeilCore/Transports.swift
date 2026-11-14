import Foundation
import CryptoKit

/// Line-delimited JSON-RPC over a Unix domain socket (mode 0600). The `veil-mcp`
/// stdio bridge connects here, so MCP clients never need Full Disk Access themselves.
public final class UnixSocketServer {
    public let path: String
    private let server: MCPServer
    private var fd: Int32 = -1

    public init(path: String, server: MCPServer) { self.path = path; self.server = server }

    public func start() throws {
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if Self.canConnect(path) { throw SocketError("Veil is already running.") }
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket() failed") }
        var addr = try Self.address(path)
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { close(fd); throw SocketError("bind() failed: \(String(cString: strerror(errno)))") }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else { close(fd); throw SocketError("listen() failed") }
        acceptor = Acceptor(fd: fd, maxConnections: 32) { [weak self] c in self?.serve(c) }
    }

    private var acceptor: Acceptor?

    public func stop() { acceptor?.stop(); acceptor = nil; fd = -1; unlink(path) }

    private func serve(_ c: Int32) {
        var nosig: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        let session = server.makeSession()
        defer { session.close(); close(c) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(c, &chunk, chunk.count)
            if n <= 0 { return }
            buffer.append(contentsOf: chunk[0..<n])
            guard buffer.count < 8_000_000 else { return }
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer = Data(buffer[(nl + 1)...])
                guard !line.isEmpty else { continue }
                let reply: JSON? = JSON.parse(Data(line)).map { session.handle($0) }
                    ?? ["jsonrpc": "2.0", "id": nil, "error": ["code": -32700, "message": "Parse error"]]
                if let reply { writeAll(c, Data((reply.encoded() + "\n").utf8)) }
            }
        }
    }

    static func canConnect(_ path: String) -> Bool {
        let s = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(s) }
        guard var addr = try? address(path) else { return false }
        return withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw SocketError("Socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in for (i, b) in bytes.enumerated() { raw[i] = b } }
        return addr
    }
}

/// Optional MCP "Streamable HTTP" endpoint on 127.0.0.1 for assistants that can't launch a
/// command. Requires a bearer token and rejects browser cross-origin requests.
public final class LocalHTTPServer {
    public let port: UInt16
    private let token: String
    private let server: MCPServer
    private var fd: Int32 = -1
    private var sessions: [String: MCPServer.Session] = [:]
    private var sessionOrder: [String] = []
    private let lock = NSLock()

    public init(port: UInt16, token: String, server: MCPServer) { self.port = port; self.token = token; self.server = server }

    public func start() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError("socket() failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")   // loopback only, never the network
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0, listen(fd, 16) == 0 else { close(fd); throw SocketError("Port \(port) is busy.") }
        acceptor = Acceptor(fd: fd, maxConnections: 16) { [weak self] c in
            // One request per connection; don't let a silent client hold a thread.
            var tv = timeval(tv_sec: 15, tv_usec: 0)
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            self?.serve(c)
        }
    }

    private var acceptor: Acceptor?

    public func stop() {
        acceptor?.stop(); acceptor = nil; fd = -1
        lock.lock(); let all = sessions.values; sessions = [:]; sessionOrder = []; lock.unlock()
        all.forEach { $0.close() }
    }

    private func serve(_ c: Int32) {
        var nosig: Int32 = 1
        setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        defer { close(c) }
        guard let req = HTTPRequest.read(c) else { return }
        let (status, headers, body) = respond(req)
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        writeAll(c, Data((head + "\r\n").utf8) + body)
    }

    func respond(_ r: HTTPRequest) -> (String, [String: String], Data) {
        let plain = ["Content-Type": "text/plain"]
        let host = r.headers["host"] ?? ""
        guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else { return ("421 Misdirected Request", plain, Data("Bad host".utf8)) }
        if let origin = r.headers["origin"], !["127.0.0.1", "localhost"].contains(URLComponents(string: origin)?.host ?? "") {
            return ("403 Forbidden", plain, Data("Cross-origin requests are not allowed".utf8))
        }
        let given = Data((r.headers["authorization"] ?? "").utf8)
        let expected = Data("Bearer \(token)".utf8)
        guard SHA256.hash(data: given) == SHA256.hash(data: expected) else { return ("401 Unauthorized", plain, Data("Missing or wrong token".utf8)) }
        guard r.path == "/mcp" else { return ("404 Not Found", plain, Data()) }

        let sid = r.headers["mcp-session-id"]
        switch r.method {
        case "DELETE":
            if let sid { lock.lock(); let s = sessions.removeValue(forKey: sid); sessionOrder.removeAll { $0 == sid }; lock.unlock(); s?.close() }
            return ("200 OK", plain, Data())
        case "POST":
            guard let msg = JSON.parse(r.body) else { return ("400 Bad Request", plain, Data("Parse error".utf8)) }
            var headers = ["Content-Type": "application/json"]
            let session: MCPServer.Session
            lock.lock()
            if msg["method"]?.string == "initialize" {
                session = server.makeSession()
                let newID = UUID().uuidString
                if sessionOrder.count >= 32 { let oldest = sessionOrder.removeFirst(); sessions.removeValue(forKey: oldest)?.close() }
                sessions[newID] = session
                sessionOrder.append(newID)
                headers["Mcp-Session-Id"] = newID
            } else if let sid, let s = sessions[sid] {
                session = s
            } else {
                // Stateless clients: one-off session.
                session = server.makeSession()
            }
            lock.unlock()
            guard let reply = session.handle(msg) else { return ("202 Accepted", [:], Data()) }
            return ("200 OK", headers, Data(reply.encoded().utf8))
        default:
            return ("405 Method Not Allowed", ["Allow": "POST, DELETE"], Data())
        }
    }
}

struct HTTPRequest {
    var method = "", path = "", headers: [String: String] = [:], body = Data()

    static func read(_ c: Int32) -> HTTPRequest? {
        var buf = Data()
        var chunk = [UInt8](repeating: 0, count: 16384)
        let sep = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = Darwin.read(c, &chunk, chunk.count)
            if n <= 0 || buf.count > 64_000 { return nil }
            buf.append(contentsOf: chunk[0..<n])
            headerEnd = buf.range(of: sep)
        }
        guard let end = headerEnd else { return nil }
        let lines = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var r = HTTPRequest(method: String(first[0]), path: String(first[1]))
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            r.headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = min(Int(r.headers["content-length"] ?? "0") ?? 0, 8_000_000)
        r.body = Data(buf[end.upperBound...])
        while r.body.count < length {
            let n = Darwin.read(c, &chunk, chunk.count)
            if n <= 0 { return nil }
            r.body.append(contentsOf: chunk[0..<n])
        }
        return r
    }
}

/// Accepts connections on a listening socket until stopped. Transient errors (out of file
/// descriptors, aborted connections) pause briefly instead of ending the loop, and the number
/// of simultaneous connections is capped. `handle` owns and must close each connection.
final class Acceptor {
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    private var open = 0

    init(fd: Int32, maxConnections: Int, handle: @escaping (Int32) -> Void) {
        self.fd = fd
        Thread.detachNewThread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                lock.lock(); let isStopped = stopped; lock.unlock()
                if isStopped { if c >= 0 { close(c) }; return }
                if c < 0 { usleep(errno == EINTR ? 0 : 100_000); continue }
                lock.lock()
                guard open < maxConnections else { lock.unlock(); close(c); continue }
                open += 1
                lock.unlock()
                Thread.detachNewThread { [self] in
                    handle(c)
                    lock.lock(); open -= 1; lock.unlock()
                }
            }
        }
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        close(fd)   // wakes the blocked accept()
    }
}

struct SocketError: LocalizedError { let message: String; init(_ m: String) { message = m }; var errorDescription: String? { message } }

func writeAll(_ fd: Int32, _ data: Data) {
    data.withUnsafeBytes { raw in
        var off = 0
        while off < raw.count {
            let n = write(fd, raw.baseAddress! + off, raw.count - off)
            if n <= 0 { return }
            off += n
        }
    }
}
