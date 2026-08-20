import Foundation
import SQLite3

/// Tells sqlite3_bind_text to copy the string immediately rather than
/// assume the caller keeps the buffer alive. Standard idiom since Swift
/// doesn't import the SQLITE_TRANSIENT macro.
private let SQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum SQLiteError: Error, CustomStringConvertible {
    case openFailed(String)
    case execFailed(String)
    case prepareFailed(String)
    case stepFailed(String)

    var description: String {
        switch self {
        case .openFailed(let message): return "sqlite open failed: \(message)"
        case .execFailed(let message): return "sqlite exec failed: \(message)"
        case .prepareFailed(let message): return "sqlite prepare failed: \(message)"
        case .stepFailed(let message): return "sqlite step failed: \(message)"
        }
    }
}

/// Values that can be bound to a prepared statement, by 1-based position.
enum SQLiteValue {
    case text(String)
    case int64(Int64)
    case null
}

/// Thin wrapper around the system libsqlite3 C API. Not a general-purpose
/// ORM — only the handful of operations RecordStore needs: run a statement,
/// run a query and read rows back, and manage PRAGMA user_version.
final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            throw SQLiteError.openFailed(message)
        }
        handle = db
        sqlite3_busy_timeout(handle, 5000)
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs one or more `;`-separated statements with no bindings and no
    /// result rows. Used for schema DDL, transaction control and PRAGMAs.
    func exec(_ sql: String) throws {
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            throw SQLiteError.execFailed(lastErrorMessage())
        }
    }

    /// Runs a single statement with positional bindings, expecting no rows
    /// (INSERT / UPDATE / DELETE).
    func run(_ sql: String, bindings: [SQLiteValue] = []) throws {
        let stmt = try prepareStatement(sql, bindings: bindings)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SQLiteError.stepFailed(lastErrorMessage())
        }
    }

    /// Runs a SELECT and invokes `row` once per result row, passing the
    /// statement handle for column extraction via `columnText`/`columnInt64`.
    func query(_ sql: String, bindings: [SQLiteValue] = [], row: (OpaquePointer) -> Void) throws {
        let stmt = try prepareStatement(sql, bindings: bindings)
        defer { sqlite3_finalize(stmt) }
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                row(stmt)
            } else if result == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.stepFailed(lastErrorMessage())
            }
        }
    }

    func userVersion() throws -> Int {
        var version = 0
        try query("PRAGMA user_version;") { stmt in
            version = Int(sqlite3_column_int(stmt, 0))
        }
        return version
    }

    /// Not user input — safe to interpolate; PRAGMA doesn't accept `?` bindings.
    func setUserVersion(_ version: Int) throws {
        try exec("PRAGMA user_version = \(version);")
    }

    private func prepareStatement(_ sql: String, bindings: [SQLiteValue]) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError.prepareFailed(lastErrorMessage())
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .text(let string):
                sqlite3_bind_text(stmt, index, string, -1, SQLiteTransient)
            case .int64(let number):
                sqlite3_bind_int64(stmt, index, number)
            case .null:
                sqlite3_bind_null(stmt, index)
            }
        }
        return stmt
    }

    private func lastErrorMessage() -> String {
        String(cString: sqlite3_errmsg(handle))
    }
}

func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: cString)
}

func columnInt64(_ stmt: OpaquePointer, _ index: Int32) -> Int64 {
    sqlite3_column_int64(stmt, index)
}

func columnInt64OrNil(_ stmt: OpaquePointer, _ index: Int32) -> Int64? {
    sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, index)
}
