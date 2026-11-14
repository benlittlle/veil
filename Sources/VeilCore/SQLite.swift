import Foundation
import SQLite3

/// A deliberately tiny SQLite wrapper. Read-only by construction when opened with `readOnly: true`.
final class SQLiteDB {
    enum Value { case int(Int64), double(Double), text(String), blob(Data), null }
    struct Failure: Error, CustomStringConvertible { let description: String }

    private var handle: OpaquePointer?
    private let lock = NSLock()

    init(path: String, readOnly: Bool) throws {
        let flags = readOnly
            ? (SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX)
            : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        let target = readOnly ? "file:\(path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)?mode=ro" : path
        let rc = sqlite3_open_v2(target, &handle, flags, nil)
        guard rc == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(rc)"
            sqlite3_close(handle)
            throw Failure(description: "Could not open \(path): \(message)")
        }
        sqlite3_busy_timeout(handle, 2000)
        if readOnly { _ = try? query("PRAGMA query_only = ON") }
    }

    deinit { sqlite3_close(handle) }

    @discardableResult
    func query(_ sql: String, _ params: [Value] = []) throws -> [[String: Value]] {
        var rows: [[String: Value]] = []
        try each(sql, params) { rows.append($0); return true }
        return rows
    }

    /// Streams rows; return false from `row` to stop early.
    func each(_ sql: String, _ params: [Value], _ body: ([String: Value]) -> Bool) throws {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw Failure(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, transient)
            case .blob(let v): _ = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(v.count), transient) }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure(description: String(cString: sqlite3_errmsg(handle))) }
            var row: [String: Value] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .double(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    row[name] = n > 0 ? .blob(Data(bytes: sqlite3_column_blob(stmt, c), count: n)) : .blob(Data())
                default: row[name] = .null
                }
            }
            if !body(row) { break }
        }
    }
}

extension Dictionary where Key == String, Value == SQLiteDB.Value {
    func int(_ k: String) -> Int64? { if case .int(let v)? = self[k] { return v }; if case .double(let d)? = self[k] { return Int64(d) }; return nil }
    func str(_ k: String) -> String? { if case .text(let v)? = self[k] { return v }; return nil }
    func blob(_ k: String) -> Data? { if case .blob(let v)? = self[k] { return v }; return nil }
}
