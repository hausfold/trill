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
                payload   TEXT NOT NULL,
                read_at   REAL,
                kind      TEXT
            )
            """)
        // Databases written before the inbox grew unread state have every
        // column but this one. Added rather than migrated-by-recreate: the
        // rows are the user's history, and NULL is exactly the right answer
        // for a row nobody could have marked read yet.
        addColumn("read_at REAL", to: "events", ifMissing: "read_at")
        // The kind, lifted out of the payload so a catch-up card can be one
        // `GROUP BY` instead of a JSON decode per row. That matters at
        // exactly the moment it runs: someone just unlocked their Mac after a
        // night of traffic, and the count has to be there before the card is.
        // Old rows have no kind and are counted as notes — which is what an
        // event that never named one decodes as anyway.
        addColumn("kind TEXT", to: "events", ifMissing: "kind")
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

    /// Write one delivered event, already read or not.
    ///
    /// **Unread means trill never put this in front of you.** A `banner`
    /// decision is stamped read on the way in — it was drawn on a screen,
    /// which is the closest thing this app has to "seen" — while everything
    /// held back (quiet hours, an `inbox` rule, a digest tally) arrives
    /// unread. That is what makes the inbox's unread count worth reading: it
    /// counts exactly the things you would otherwise never learn about,
    /// rather than re-reporting every banner that already interrupted you.
    ///
    /// `seen` is the other half of that sentence, and the reason it takes a
    /// parameter rather than reading the decision alone: **a banner drawn at
    /// a locked screen was never put in front of anybody.** It played to an
    /// empty room, and calling it read is how a night's worth of traffic
    /// disappears from both the unread count and the catch-up card. The
    /// caller answers "was anyone here" (`PresenceFlag`); this only records
    /// it.
    func insert(
        _ event: NotificationEvent,
        decision: DeliveryDecision,
        seen: Bool = true,
        now: Date = .now
    ) {
        guard let payload = try? String(data: JSONEncoder.trill.encode(event), encoding: .utf8) ?? ""
        else { return }
        let decisionLabel = Self.label(for: decision)
        let readAt: Double? = decision.isBanner && seen ? now.timeIntervalSince1970 : nil
        let kind = event.kind.rawValue

        queue.async { [self] in
            guard let db else { return }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                db,
                """
                INSERT OR IGNORE INTO events (id, source, timestamp, decision, payload, read_at, kind)
                VALUES (?,?,?,?,?,?,?)
                """,
                -1, &statement, nil
            ) == SQLITE_OK else { return }
            sqlite3_bind_text(statement, 1, event.id, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, event.source, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 3, event.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(statement, 4, decisionLabel, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 5, payload, -1, SQLITE_TRANSIENT)
            if let readAt {
                sqlite3_bind_double(statement, 6, readAt)
            } else {
                sqlite3_bind_null(statement, 6)
            }
            sqlite3_bind_text(statement, 7, kind, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) != SQLITE_DONE {
                Self.log.error("insert failed for \(event.id, privacy: .public)")
            }
        }
    }

    /// Mark events read (or back to unread). Fire-and-forget like every other
    /// write here — the inbox moves its own dot the instant you click, and
    /// this is the copy that has to survive the window closing.
    func setRead(_ read: Bool, ids: [String], now: Date = .now) {
        guard !ids.isEmpty else { return }
        let stamp = now.timeIntervalSince1970
        queue.async { [self] in
            guard let db else { return }
            sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
            for id in ids {
                var statement: OpaquePointer?
                defer { sqlite3_finalize(statement) }
                guard sqlite3_prepare_v2(
                    db, "UPDATE events SET read_at = ? WHERE id = ?", -1, &statement, nil
                ) == SQLITE_OK else { continue }
                if read {
                    sqlite3_bind_double(statement, 1, stamp)
                } else {
                    sqlite3_bind_null(statement, 1)
                }
                sqlite3_bind_text(statement, 2, id, -1, SQLITE_TRANSIENT)
                sqlite3_step(statement)
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    func recent(limit: Int = 100, source: String? = nil) -> [InboxEntry] {
        queue.sync { [self] in
            guard let db else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }

            let sql = source == nil
                ? "SELECT payload, decision, read_at FROM events ORDER BY timestamp DESC LIMIT ?"
                : "SELECT payload, decision, read_at FROM events WHERE source = ? ORDER BY timestamp DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }

            var index: Int32 = 1
            if let source {
                sqlite3_bind_text(statement, index, source, -1, SQLITE_TRANSIENT)
                index += 1
            }
            sqlite3_bind_int(statement, index, Int32(max(1, limit)))
            return Self.rows(from: statement)
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

    /// The events one digest card counted: everything stamped `digest:<name>`
    /// since that card's window opened.
    ///
    /// The card is a summary of rows that are already here, so its click is a
    /// query and not a second store — nothing about a digest is persisted
    /// beyond the decision label the repository already wrote.
    func digest(named name: String, since: Date, limit: Int = 500) -> [InboxEntry] {
        queue.sync { [self] in
            guard let db else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT payload, decision, read_at FROM events
                WHERE decision = ? AND timestamp >= ?
                ORDER BY timestamp DESC LIMIT ?
                """,
                -1, &statement, nil
            ) == SQLITE_OK else { return [] }
            sqlite3_bind_text(statement, 1, "digest:\(name)", -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(statement, 2, since.timeIntervalSince1970)
            sqlite3_bind_int(statement, 3, Int32(max(1, limit)))
            return Self.rows(from: statement)
        }
    }

    /// What landed since `since` and never made it in front of the user,
    /// counted by kind — the whole of a catch-up card's arithmetic.
    ///
    /// A `GROUP BY` over a column rather than a fetch-and-decode, because
    /// this is the one query in the app whose input size is "however much
    /// arrived overnight". It returns six numbers at most however loud the
    /// night was, so the card is a constant-cost read of an unbounded window
    /// — and it can never quietly truncate the way a `LIMIT`ed fetch would,
    /// which for a card whose entire content is a count would be a wrong
    /// number rather than a short list.
    ///
    /// Unread is the filter, not the timestamp alone: a banner drawn while
    /// somebody was sitting here is not something they missed, even if it
    /// landed inside the window (see `insert`).
    func missedCounts(since: Date) -> [NotificationEvent.Kind: Int] {
        queue.sync { [self] in
            guard let db else { return [:] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT kind, COUNT(*) FROM events
                WHERE timestamp >= ? AND read_at IS NULL
                GROUP BY kind
                """,
                -1, &statement, nil
            ) == SQLITE_OK else { return [:] }
            sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)

            var counts: [NotificationEvent.Kind: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                // A row with no kind predates the column; a row with a kind
                // this build has never heard of came from a newer one. Both
                // count as notes, which is what `NotificationEvent` decodes
                // an unnamed kind as — the card would rather say "14 notes"
                // than drop fourteen things out of its own total.
                let raw = sqlite3_column_text(statement, 0).map { String(cString: $0) }
                let kind = raw.flatMap(NotificationEvent.Kind.init(rawValue:)) ?? .note
                counts[kind, default: 0] += Int(sqlite3_column_int(statement, 1))
            }
            return counts
        }
    }

    /// Everything stored since an instant — what a catch-up card's click
    /// opens. Same shape as `digest(named:since:)`: the card is a summary of
    /// rows that are already here, so its click is a query and not a second
    /// store.
    func events(since: Date, limit: Int = 500) -> [InboxEntry] {
        queue.sync { [self] in
            guard let db else { return [] }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT payload, decision, read_at FROM events
                WHERE timestamp >= ?
                ORDER BY timestamp DESC LIMIT ?
                """,
                -1, &statement, nil
            ) == SQLITE_OK else { return [] }
            sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
            sqlite3_bind_int(statement, 2, Int32(max(1, limit)))
            return Self.rows(from: statement)
        }
    }

    /// Drains a `(payload, decision, read_at)` statement. A row whose payload
    /// no longer decodes — written by a build that spelled the event
    /// differently — is skipped rather than failing the whole read.
    private static func rows(from statement: OpaquePointer?) -> [InboxEntry] {
        var results: [InboxEntry] = []
        let decoder = JSONDecoder.trill
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let payloadText = sqlite3_column_text(statement, 0),
                let decisionText = sqlite3_column_text(statement, 1),
                let event = try? decoder.decode(
                    NotificationEvent.self, from: Data(String(cString: payloadText).utf8)
                )
            else { continue }
            let readAt = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            results.append(InboxEntry(
                event: event, decision: String(cString: decisionText), readAt: readAt
            ))
        }
        return results
    }

    /// `ALTER TABLE … ADD COLUMN` guarded by a schema read, because SQLite
    /// has no `IF NOT EXISTS` for columns and running it blind would log a
    /// failure on every launch after the first.
    private func addColumn(_ declaration: String, to table: String, ifMissing column: String) {
        let existing: Bool = queue.sync {
            guard let db else { return true }
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(
                db, "PRAGMA table_info(\(table))", -1, &statement, nil
            ) == SQLITE_OK else { return true }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let name = sqlite3_column_text(statement, 1) else { continue }
                if String(cString: name) == column { return true }
            }
            return false
        }
        guard !existing else { return }
        exec("ALTER TABLE \(table) ADD COLUMN \(declaration)")
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
        // Its own label, not "banner": a fin is a question waiting on the
        // edge of the screen, and the inbox has to be able to say so — and
        // to leave it *unread*, because trill deliberately did not put it in
        // front of anyone.
        case .ledge: "ledge"
        case .drop: "drop"
        }
    }
}
