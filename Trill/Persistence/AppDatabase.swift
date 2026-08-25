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
        // The ledge, mirrored. Its own table and not a column on `events`
        // because it holds a *different* thing: `events` is history (append
        // only, pruned by age), this is the list of questions still open
        // right now — five rows at most, rewritten wholesale whenever the
        // bucket changes. `BannerQueue.parked` stays the truth; this is a
        // copy that survives a relaunch, and a copy is allowed to be stale
        // for exactly as long as the daemon is down.
        exec("""
            CREATE TABLE IF NOT EXISTS ledge (
                id        TEXT PRIMARY KEY,
                parked_at REAL NOT NULL,
                coalesced INTEGER NOT NULL,
                payload   TEXT NOT NULL
            )
            """)
    }

    /// One open question, as it survives a relaunch: the face event and how
    /// many thread-mates were behind it. The folded list itself is dropped —
    /// it's in `events`, and the parked card never drew it anyway.
    struct StoredParked: Sendable {
        let event: NotificationEvent
        let coalescedCount: Int
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

    /// Mirror the whole ledge. Wholesale rather than per-entry insert/delete
    /// because the bucket is five rows and a diff is a way to drift out of
    /// sync with the only truth there is — every fin appearing, answering or
    /// yielding lands here as the same complete list.
    func saveLedge(_ entries: [StoredParked]) {
        let rows: [(String, Double, Int, String)] = entries.compactMap { parked in
            guard let payload = try? String(
                data: JSONEncoder.trill.encode(parked.event), encoding: .utf8
            ) else { return nil }
            return (parked.event.id, parked.event.timestamp.timeIntervalSince1970,
                    parked.coalescedCount, payload)
        }

        queue.async { [self] in
            guard let db else { return }
            sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM ledge", nil, nil, nil)
            for row in rows {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(
                    db,
                    "INSERT OR REPLACE INTO ledge (id, parked_at, coalesced, payload) VALUES (?,?,?,?)",
                    -1, &statement, nil
                ) == SQLITE_OK else { continue }
                sqlite3_bind_text(statement, 1, row.0, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(statement, 2, row.1)
                sqlite3_bind_int(statement, 3, Int32(row.2))
                sqlite3_bind_text(statement, 4, row.3, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE {
                    Self.log.error("ledge write failed for \(row.0, privacy: .public)")
                }
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    /// The ledge as it was, oldest first — the order fins hang in. Anything
    /// older than `maxAge` is left behind *and deleted*: a question nobody
    /// answered in a week is not a question any more, and a fin that outlives
    /// its own subject teaches you to ignore the edge of your screen.
    func parkedLedge(maxAge: TimeInterval, now: Date = .now) -> [StoredParked] {
        let cutoff = now.timeIntervalSince1970 - maxAge
        return queue.sync { [self] in
            guard let db else { return [] }
            var deleteStale: OpaquePointer?
            if sqlite3_prepare_v2(
                db, "DELETE FROM ledge WHERE parked_at < ?", -1, &deleteStale, nil
            ) == SQLITE_OK {
                sqlite3_bind_double(deleteStale, 1, cutoff)
                sqlite3_step(deleteStale)
            }
            sqlite3_finalize(deleteStale)

            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                db, "SELECT payload, coalesced FROM ledge ORDER BY parked_at ASC", -1, &statement, nil
            ) == SQLITE_OK else { return [] }

            var results: [StoredParked] = []
            let decoder = JSONDecoder.trill
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let payloadText = sqlite3_column_text(statement, 0),
                      let event = try? decoder.decode(
                          NotificationEvent.self, from: Data(String(cString: payloadText).utf8)
                      )
                else { continue }
                results.append(StoredParked(
                    event: event, coalescedCount: Int(sqlite3_column_int(statement, 1))
                ))
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
