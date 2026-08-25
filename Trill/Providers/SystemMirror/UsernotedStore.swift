import Foundation
import SQLite3

/// The read-only half of System Mirror: one SQLite connection to Apple's
/// `usernoted` store, and nothing that can write to it.
///
/// Everything undocumented lives here or in `UsernotedRecord` — the file
/// path, the table names, the four-letter plist keys, the 2001 epoch. The
/// rest of the app sees `NotificationEvent`s.
///
/// Quarantine rules this type is where they are enforced:
///   - opened `SQLITE_OPEN_READONLY`, never a write-capable flag, and never
///     with `sqlite3_open` (which creates);
///   - the schema is probed before every session, and drift disables the
///     provider with a reason rather than being guessed around;
///   - a read that fails is reported, never repaired.
final class UsernotedStore {
    /// Tables the reader needs. If Apple renames or reshapes either of them
    /// the probe fails closed and says which one went missing.
    static let expectedTables: Set<String> = ["record", "app"]
    /// Columns of `record` the reader actually reads. Table presence isn't
    /// enough: `record` surviving a macOS update with `data` renamed would
    /// pass a table-name probe and then decode nothing, forever, quietly.
    static let expectedColumns: Set<String> = [
        "rec_id", "app_id", "uuid", "data", "delivered_date", "style",
    ]

    /// The most rows one read will take. A backlog — a Mac waking to a
    /// hundred queued notifications — is drained a batch at a time rather
    /// than dropped or fired at the compositor all at once.
    static let batchLimit = 50

    enum OpenError: Error {
        /// The file isn't there, or this process can't see it. On a
        /// TCC-protected path those are the same error and it is Full Disk
        /// Access either way.
        case unreadable(String)
        /// Apple changed the schema under us.
        case schemaDrift(String)
    }

    static func defaultPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
            .path
    }

    /// The write-ahead log beside the store. Watched rather than polled:
    /// usernoted commits there, and the row becomes visible to a reader in
    /// the same instant the file changes.
    static func walPath(for storePath: String) -> String { storePath + "-wal" }

    private let path: String
    private var handle: OpaquePointer?

    init(path: String = UsernotedStore.defaultPath()) {
        self.path = path
    }

    deinit { close() }

    // MARK: - Session

    /// Open read-only and check the shape. Throws rather than returning a
    /// half-usable connection: "off with a reason" is the only failure mode
    /// this provider has.
    func open() throws {
        close()
        guard FileManager.default.fileExists(atPath: path) else {
            throw OpenError.unreadable("usernoted store not found (needs Full Disk Access, or the layout moved)")
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            throw OpenError.unreadable("usernoted store unreadable (grant Full Disk Access to Trill)")
        }
        handle = db

        // A read-only connection to a WAL database still needs to map the
        // `-shm` index, so "opened" is not "readable". Ask it a question
        // before believing it.
        let tables = try queryStrings("SELECT name FROM sqlite_master WHERE type = 'table'")
        let missingTables = Self.expectedTables.subtracting(tables)
        guard missingTables.isEmpty else {
            close()
            throw OpenError.schemaDrift(
                "usernoted schema drifted (missing \(missingTables.sorted().joined(separator: ", "))) — provider disabled until updated for this macOS"
            )
        }
        let columns = try queryStrings("SELECT name FROM pragma_table_info('record')")
        let missingColumns = Self.expectedColumns.subtracting(columns)
        guard missingColumns.isEmpty else {
            close()
            throw OpenError.schemaDrift(
                "usernoted's record table drifted (missing \(missingColumns.sorted().joined(separator: ", "))) — provider disabled until updated for this macOS"
            )
        }
    }

    func close() {
        if let handle { sqlite3_close(handle) }
        handle = nil
    }

    var isOpen: Bool { handle != nil }

    // MARK: - Reads

    /// The newest row id, or 0 for an empty store. Read once at stream start
    /// so a launch mirrors what happens *next* rather than replaying whatever
    /// is still sitting in Notification Center.
    func latestRecordID() throws -> Int64 {
        guard let handle else { throw OpenError.unreadable("usernoted store is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT COALESCE(MAX(rec_id), 0) FROM record", -1, &statement, nil) == SQLITE_OK
        else { throw OpenError.unreadable(lastErrorMessage()) }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    /// Rows newer than `watermark`, oldest first, capped at `batchLimit`.
    /// Rows that don't decode are skipped rather than throwing: one
    /// unreadable notification is not a reason to take the source down.
    func records(after watermark: Int64) throws -> [UsernotedRecord] {
        guard let handle else { throw OpenError.unreadable("usernoted store is closed") }
        let sql = """
            SELECT r.rec_id, r.uuid, r.data, r.delivered_date, r.style, a.identifier
            FROM record r LEFT JOIN app a ON a.app_id = r.app_id
            WHERE r.rec_id > ?
            ORDER BY r.rec_id
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw OpenError.unreadable(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, watermark)
        sqlite3_bind_int(statement, 2, Int32(Self.batchLimit))

        var records: [UsernotedRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let recordID = sqlite3_column_int64(statement, 0)
            let uuid = Self.uuid(from: statement, column: 1)
            guard var plist = Self.plist(from: statement, column: 2) else { continue }
            let delivered = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 3)
            let style = Int(sqlite3_column_int(statement, 4))
            // The blob usually names its own app in canonical case; the `app`
            // table only ever has it lowercased. Prefer the blob, fall back
            // to the join, so a row missing one still has a source.
            if plist["app"] == nil, let identifier = sqlite3_column_text(statement, 5) {
                plist["app"] = String(cString: identifier)
            }
            if let record = UsernotedRecord(
                recordID: recordID, uuid: uuid, style: style,
                deliveredDate: delivered, plist: plist
            ) {
                records.append(record)
            }
        }
        return records
    }

    // MARK: - Decoding

    private static func uuid(from statement: OpaquePointer?, column: Int32) -> UUID? {
        guard let bytes = sqlite3_column_blob(statement, column),
              sqlite3_column_bytes(statement, column) == 16
        else { return nil }
        var raw = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &raw) { destination in
            destination.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: 16))
        }
        return UUID(uuid: raw)
    }

    private static func plist(from statement: OpaquePointer?, column: Int32) -> [String: Any]? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return nil }
        let data = Data(bytes: bytes, count: count)
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private func queryStrings(_ sql: String) throws -> Set<String> {
        guard let handle else { throw OpenError.unreadable("usernoted store is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw OpenError.unreadable(lastErrorMessage())
        }
        defer { sqlite3_finalize(statement) }
        var values: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 0) { values.insert(String(cString: text)) }
        }
        return values
    }

    private func lastErrorMessage() -> String {
        guard let handle, let message = sqlite3_errmsg(handle) else {
            return "usernoted store unreadable (grant Full Disk Access to Trill)"
        }
        return "usernoted store unreadable: \(String(cString: message))"
    }
}
