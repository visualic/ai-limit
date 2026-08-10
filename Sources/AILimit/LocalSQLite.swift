import Foundation
import SQLite3

/// Reads a SQLite database that another application owns.
///
/// Both credential sources this app reads — Chromium's cookie store and
/// Cursor's state database — are live databases belonging to a running app.
/// Querying them in place fights the owner's locks and can miss data still in
/// the write-ahead log, so every read works on a snapshot copy instead.
enum LocalSQLite {

    /// Copies `source` (with its `-wal`/`-shm` siblings) somewhere private,
    /// opens it read-only, and hands the connection to `body`. The copy is
    /// always removed, including when `body` throws.
    static func withReadOnlyCopy<T>(
        of source: URL,
        _ body: (OpaquePointer) throws -> T
    ) rethrows -> T? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { return nil }

        let scratch = fm.temporaryDirectory
            .appendingPathComponent("ailimit-\(UUID().uuidString).db")
        defer {
            // The sidecar files are recreated by SQLite on open, so clean all three.
            for suffix in ["", "-wal", "-shm"] {
                try? fm.removeItem(at: URL(fileURLWithPath: scratch.path + suffix))
            }
        }

        do {
            try fm.copyItem(at: source, to: scratch)
        } catch {
            return nil
        }
        // Without the write-ahead log, recently written rows are invisible.
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: source.path + suffix)
            if fm.fileExists(atPath: sidecar.path) {
                try? fm.copyItem(at: sidecar, to: URL(fileURLWithPath: scratch.path + suffix))
            }
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(scratch.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let handle else {
            return nil
        }
        defer { sqlite3_close(handle) }
        return try body(handle)
    }

    /// SQLite must copy bound text before the statement is stepped, because the
    /// Swift string backing it may not outlive the call.
    static let transientText = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func integer(_ db: OpaquePointer, _ sql: String) -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        if let text = sqlite3_column_text(statement, 0) { return Int(String(cString: text)) }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
