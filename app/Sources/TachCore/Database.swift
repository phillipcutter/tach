import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct DBError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// A value bound to a statement parameter.
public enum DBValue {
    case int(Int64), double(Double), text(String), null

    public static func from(_ v: Int64?) -> DBValue { v.map { .int($0) } ?? .null }
    public static func from(_ v: Int?) -> DBValue { v.map { .int(Int64($0)) } ?? .null }
    public static func from(_ v: Double?) -> DBValue { v.map { .double($0) } ?? .null }
    public static func from(_ v: String?) -> DBValue { v.map { .text($0) } ?? .null }
    public static func from(_ v: Bool?) -> DBValue { v.map { .int($0 ? 1 : 0) } ?? .null }
}

/// One result row. Column indexes are zero-based.
public struct Row {
    let stmt: OpaquePointer
    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func intOrNil(_ i: Int32) -> Int64? { isNull(i) ? nil : sqlite3_column_int64(stmt, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func doubleOrNil(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(stmt, i) }
    public func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
    public func textOrNil(_ i: Int32) -> String? { isNull(i) ? nil : text(i) }
}

public final class Statement {
    fileprivate var handle: OpaquePointer?
    private let db: OpaquePointer

    fileprivate init(db: OpaquePointer, sql: String) throws {
        self.db = db
        guard sqlite3_prepare_v2(db, sql, -1, &handle, nil) == SQLITE_OK else {
            throw DBError(message: "prepare: \(String(cString: sqlite3_errmsg(db))) in \(sql)")
        }
    }

    deinit { sqlite3_finalize(handle) }

    private func bind(_ args: [DBValue]) {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (n, a) in args.enumerated() {
            let i = Int32(n + 1)
            switch a {
            case .int(let v): sqlite3_bind_int64(handle, i, v)
            case .double(let v): sqlite3_bind_double(handle, i, v)
            case .text(let v): sqlite3_bind_text(handle, i, v, -1, SQLITE_TRANSIENT)
            case .null: sqlite3_bind_null(handle, i)
            }
        }
    }

    public func run(_ args: [DBValue] = []) throws {
        bind(args)
        let rc = sqlite3_step(handle)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw DBError(message: "step: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_reset(handle)
    }

    public func query(_ args: [DBValue] = [], _ each: (Row) -> Void) throws {
        bind(args)
        guard let h = handle else { return }
        while true {
            let rc = sqlite3_step(h)
            if rc == SQLITE_ROW { each(Row(stmt: h)) } else if rc == SQLITE_DONE { break } else {
                throw DBError(message: "step: \(String(cString: sqlite3_errmsg(db)))")
            }
        }
        sqlite3_reset(h)
    }
}

/// A thin SQLite wrapper. Not thread-safe: use it from one queue.
public final class Database {
    private var handle: OpaquePointer?
    private var cache: [String: Statement] = [:]

    public init(path: String) throws {
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            throw DBError(message: "cannot open \(path)")
        }
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;")
    }

    deinit {
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    public func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let m = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            throw DBError(message: "exec: \(m)")
        }
    }

    /// Returns a cached prepared statement for `sql`.
    public func statement(_ sql: String) throws -> Statement {
        if let s = cache[sql] { return s }
        let s = try Statement(db: handle!, sql: sql)
        cache[sql] = s
        return s
    }

    public func run(_ sql: String, _ args: [DBValue] = []) throws { try statement(sql).run(args) }

    public func query(_ sql: String, _ args: [DBValue] = [], _ each: (Row) -> Void) throws {
        try statement(sql).query(args, each)
    }

    public func scalarInt(_ sql: String, _ args: [DBValue] = []) throws -> Int64? {
        var out: Int64?
        try query(sql, args) { r in if out == nil { out = r.intOrNil(0) } }
        return out
    }

    public func transaction(_ body: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do {
            try body()
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
}
