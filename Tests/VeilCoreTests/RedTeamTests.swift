import Foundation
import Testing
@testable import VeilCore

/// Regressions for the red-team pass: each test is an attack that used to work.
@Suite("Red team")
struct RedTeamTests {
    /// Sends lines to a fresh socket server and returns the reply lines, in order.
    func socketExchange(_ h: Harness, _ lines: [String], replies: Int) throws -> [String] {
        let path = "/tmp/veil-\(UUID().uuidString.prefix(8)).sock"
        let sock = UnixSocketServer(path: path, server: h.server)
        try sock.start(); defer { sock.stop() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0); defer { close(fd) }
        var nosig: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = try UnixSocketServer.address(path)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        try #require(rc == 0)
        writeAll(fd, Data(lines.map { $0 + "\n" }.joined().utf8))
        var got = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while got.filter({ $0 == 0x0A }).count < replies {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            got.append(contentsOf: buf[0..<n])
        }
        return String(decoding: got, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    // MARK: - Deeply nested JSON

    /// One short line of nested brackets (under the JSON decoder's own limit of 512 levels) used to overflow
    /// the connection thread's stack while it was parsed, crashing Veil for every assistant.
    @Test func deeplyNestedJSONIsRefusedNotFatal() throws {
        let h = try Harness()
        let deep = String(repeating: "[", count: 500) + String(repeating: "]", count: 500)
        let deepObject = String(repeating: #"{"a":"#, count: 500) + "1" + String(repeating: "}", count: 500)
        let nestedBatch = String(repeating: "[", count: 40) + #"{"jsonrpc":"2.0","id":5,"method":"ping"}"# + String(repeating: "]", count: 40)
        let replies = try socketExchange(h, [deep, deepObject, nestedBatch, #"{"jsonrpc":"2.0","id":7,"method":"ping"}"#], replies: 4)
        #expect(replies.count == 4)
        #expect(replies.prefix(2).allSatisfy { $0.contains("-32700") })
        #expect(replies[2].contains("-32600"))   // a batch inside a batch isn't a request
        #expect(replies.last?.contains(#""id":7"#) == true)
    }

    @Test func ordinaryNestingStillParses() throws {
        let line = #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","arguments":{"filter":{"categories":{"codes":"mask"}},"list":[[1,[2,"[{"]]]}}}"#
        #expect(JSON.parse(Data(line.utf8))?["params"]?["arguments"]?["filter"]?["categories"]?["codes"]?.string == "mask")
    }
}
