import Foundation
import SQLite3

public enum SQLiteError: Error, Equatable, Sendable {
    case openFailed(path: String, message: String)
    case prepareFailed(sql: String, message: String)
    case stepFailed(message: String)
    case bindFailed(message: String)
}

extension SQLiteError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .openFailed:
            return String(localized: "LumaHarbor's local index couldn't be opened.")
        case .prepareFailed, .stepFailed, .bindFailed:
            return String(localized: "LumaHarbor's local index reported an error.")
        }
    }

    public var recoverySuggestion: String? {
        // The index is disposable by design (spec §8.3), so the answer is always
        // "throw it away and rescan".
        String(localized: "Delete the local index and rescan your folders to rebuild it.")
    }
}

/// A value bound into a statement.
public enum SQLiteValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
}

/// Minimal wrapper over the system SQLite.
///
/// Hand-rolled rather than pulled from a package: the schema is small, the
/// system already ships the library, and spec §4 asks for the fewest moving
/// parts that stay reproducible.
///
/// Not thread-safe on its own — `PhotoIndexStore` owns the only instance and
/// serialises access through its actor.
final class SQLiteDatabase {
    private var handle: OpaquePointer?
    private let path: String

    /// `sqlite3_bind_text` copies the bytes when handed this destructor, which
    /// is what lets us bind a Swift `String` that dies at the end of the call.
    private static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )

    init(url: URL) throws {
        self.path = url.path
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, handle != nil else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close_v2(handle) }
            throw SQLiteError.openFailed(path: path, message: message)
        }
        self.handle = handle

        // WAL keeps the browser readable while a scan writes, and the busy
        // timeout means a slow external volume retries instead of failing.
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
            self.handle = nil
        }
    }

    private var errorMessage: String {
        guard let handle else { return "database is closed" }
        return String(cString: sqlite3_errmsg(handle))
    }

    /// Runs one or more statements with no bindings and no results.
    func execute(_ sql: String) throws {
        guard let handle else {
            throw SQLiteError.stepFailed(message: "database is closed")
        }
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(errorPointer)
            throw SQLiteError.prepareFailed(sql: sql, message: message)
        }
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ parameters: [SQLiteValue] = []) throws {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLiteError.stepFailed(message: errorMessage)
        }
    }

    /// Runs a query, mapping each row through `transform`.
    func query<T>(
        _ sql: String,
        _ parameters: [SQLiteValue] = [],
        transform: (SQLiteRow) -> T
    ) throws -> [T] {
        let statement = try prepare(sql, parameters)
        defer { sqlite3_finalize(statement) }

        var results: [T] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_ROW {
                results.append(transform(SQLiteRow(statement: statement)))
            } else if code == SQLITE_DONE {
                break
            } else {
                throw SQLiteError.stepFailed(message: errorMessage)
            }
        }
        return results
    }

    /// All-or-nothing. A scan batch that fails halfway must not leave the index
    /// describing photos it never finished reading.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try body()
            try execute("COMMIT;")
            return result
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String, _ parameters: [SQLiteValue]) throws -> OpaquePointer? {
        guard let handle else {
            throw SQLiteError.prepareFailed(sql: sql, message: "database is closed")
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            let message = errorMessage
            sqlite3_finalize(statement)
            throw SQLiteError.prepareFailed(sql: sql, message: message)
        }

        for (offset, value) in parameters.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, index)
            case .integer(let number):
                code = sqlite3_bind_int64(statement, index, number)
            case .real(let number):
                code = sqlite3_bind_double(statement, index, number)
            case .text(let string):
                code = sqlite3_bind_text(statement, index, string, -1, Self.transient)
            }
            guard code == SQLITE_OK else {
                let message = errorMessage
                sqlite3_finalize(statement)
                throw SQLiteError.bindFailed(message: message)
            }
        }
        return statement
    }
}

/// Column accessors for one result row.
struct SQLiteRow {
    private let statement: OpaquePointer?

    init(statement: OpaquePointer?) {
        self.statement = statement
    }

    func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(statement, index) == SQLITE_NULL
    }

    func int(_ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    func optionalInt(_ index: Int32) -> Int64? {
        isNull(index) ? nil : sqlite3_column_int64(statement, index)
    }

    func double(_ index: Int32) -> Double {
        sqlite3_column_double(statement, index)
    }

    func optionalDouble(_ index: Int32) -> Double? {
        isNull(index) ? nil : sqlite3_column_double(statement, index)
    }

    func string(_ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    func optionalString(_ index: Int32) -> String? {
        guard !isNull(index), let pointer = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: pointer)
    }

    func bool(_ index: Int32) -> Bool {
        sqlite3_column_int64(statement, index) != 0
    }

    func date(_ index: Int32) -> Date? {
        guard !isNull(index) else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, index))
    }
}
