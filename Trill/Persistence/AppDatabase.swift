import Foundation
import SQLite3
import os.log

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// App-owned history store: trill's inbox, digests, and `trill history` all
/// read from here. This is *our* database — the one place in the app allowed
/// to write SQL. (The usernoted store, like Messages' `chat.db`, is opened
/// read-only in its provider and never touched here.)
///
/// Persistence is a user choice: constructing with `nil` URL gives a
/// no-history mode where nothing ever hits disk.
final class AppDatabase: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.hausfold.trill.db")
    private var db: OpaquePointer?
    private static let log = Logger(subsystem: "com.hausfold.trill", category: "database")

    struct StoredEvent: Sendable, Identifiable {
        let event: NotificationEvent
        let decision: String
        var id: String { event.id }
    }

    init?(url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            Self.log.error("cannot create database directory")
            return nil
        }

        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            Self.log.error("cannot open database")
            return nil
        }
        db = handle

        exec("PRAGMA journal_mode = WAL")
        exec("""
            CREATE TABLE IF NOT EXISTS events (
                id        TEXT PRIMARY KEY,
                source    TEXT NOT NULL,
                timestamp REAL NOT NULL,
                decision  TEXT NOT NULL,
                payload   TEXT NOT NULL
            )
            """)
        exec("CREATE INDEX IF NOT EXISTS events_by_time ON events (timestamp DESC)")
        exec("CREATE INDEX IF NOT EXISTS events_by_source ON events (source, timestamp DESC)")
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    func insert(_ event: NotificationEvent, decision: DeliveryDecision) {
        guard let payload = try? String(data: JSONEncoder.trill.encode(event), encoding: .utf8) ?? ""
        else { return }
        let decisionLabel = Self.label(for: decision)

        queue.async { [self] in
            guard let db else { return }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                db,
                "INSERT OR IGNORE INTO events (id, source, timestamp, decision, payload) VALUES (?,?,?,?,?)",
                -1, &statement, nil
            ) == SQLITE_OK else { return }
            sqlite3_bind_text(statement, 1, event.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, event.source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 3, event.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(statement, 4, decisionLabel, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 5, payload, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) != SQLITE_DONE {
                Self.log.error("insert failed for \(event.id, privacy: .public)")
            }
        }
    }

    func recent(limit: Int = 100, source: String? = nil) -> [StoredEvent] {
        queue.sync { [self] in
            guard let db else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            let sql = source == nil
                ? "SELECT payload, decision FROM events ORDER BY timestamp DESC LIMIT ?"
                : "SELECT payload, decision FROM events WHERE source = ? ORDER BY timestamp DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }

            var index: Int32 = 1
            if let source {
                sqlite3_bind_text(statement, index, source, -1, SQLITE_TRANSIENT)
                index += 1
            }
            sqlite3_bind_int(statement, index, Int32(max(1, limit)))

            var results: [StoredEvent] = []
            let decoder = JSONDecoder.trill
            while sqlite3_step(statement) == SQLITE_ROW {
                guard
                    let payloadText = sqlite3_column_text(statement, 0),
                    let decisionText = sqlite3_column_text(statement, 1),
                    let event = try? decoder.decode(
                        NotificationEvent.self, from: Data(String(cString: payloadText).utf8)
                    )
                else { continue }
                results.append(StoredEvent(event: event, decision: String(cString: decisionText)))
            }
            return results
        }
    }

    /// Age-based retention; call at launch and daily.
    func prune(olderThan interval: TimeInterval) {
        queue.async { [self] in
            guard let db else { return }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                db, "DELETE FROM events WHERE timestamp < ?", -1, &statement, nil
            ) == SQLITE_OK else { return }
            sqlite3_bind_double(statement, 1, Date.now.timeIntervalSince1970 - interval)
            sqlite3_step(statement)
        }
    }

    private func exec(_ sql: String) {
        queue.sync {
            guard let db else { return }
            if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
                Self.log.error("exec failed: \(sql, privacy: .public)")
            }
        }
    }

    private static func label(for decision: DeliveryDecision) -> String {
        switch decision {
        case .banner: "banner"
        case .inboxOnly: "inbox"
        case .digest(let name): "digest:\(name)"
        case .drop: "drop"
        }
    }
}
