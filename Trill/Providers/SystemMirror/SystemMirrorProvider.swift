import Foundation
import SQLite3

/// **System Mirror — experimental.** The read-only-mirror move applied to notifications:
/// read Apple-owned state directly, read-only, and own only the presentation.
/// The source here is the `usernoted` daemon's private store
/// (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`), which —
/// unlike Messages' `chat.db` — is an undocumented implementation detail that
/// can change shape on any macOS update.
///
/// Quarantine rules (enforced here, documented in ARCHITECTURE.md):
///   - opened `SQLITE_OPEN_READONLY`, never a write-capable flag;
///   - schema probed before every session — drift disables the provider with
///     a reason, it never guesses;
///   - usernoted types stop at this file: everything is mapped to
///     `NotificationEvent` before leaving the provider;
///   - fully useful app without it. Off by default; requires Full Disk
///     Access, surfaced honestly in settings.
///
/// The ingest loop itself lands with the feasibility spike (PRD milestone 3):
/// WAL-watching vs. polling, Focus interactions, and per-app field survival
/// are measured questions, not assumptions to build on.
struct SystemMirrorProvider: NotificationProvider {
    let name = "system-mirror"
    let capabilities = ProviderCapabilities(
        canOpenSource: true,
        canDismissAtSource: false,
        experimental: true
    )

    static func defaultStorePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.usernoted/db2/db")
            .path
    }

    /// Tables the decoder needs. If Apple renames or reshapes any of them,
    /// the probe fails closed and says so.
    static let expectedTables: Set<String> = ["record", "app"]

    private let storePath: String
    init(storePath: String = SystemMirrorProvider.defaultStorePath()) {
        self.storePath = storePath
    }

    func probe() async -> ProviderHealth {
        guard FileManager.default.fileExists(atPath: storePath) else {
            return .unavailable(reason: "usernoted store not found (needs Full Disk Access, or the layout moved)")
        }

        var db: OpaquePointer?
        // READONLY and no create: if this fails we report, we don't repair.
        guard sqlite3_open_v2(storePath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            sqlite3_close(db)
            return .unavailable(reason: "usernoted store unreadable (grant Full Disk Access to Trill)")
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT name FROM sqlite_master WHERE type = 'table'", -1, &statement, nil
        ) == SQLITE_OK else {
            return .unavailable(reason: "usernoted store did not answer a schema query")
        }
        defer { sqlite3_finalize(statement) }

        var tables: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let name = sqlite3_column_text(statement, 0) {
                tables.insert(String(cString: name))
            }
        }

        let missing = Self.expectedTables.subtracting(tables)
        guard missing.isEmpty else {
            return .unavailable(reason: "usernoted schema drifted (missing \(missing.sorted().joined(separator: ", "))) — provider disabled until updated for this macOS")
        }
        return .ready
    }

    func events() async -> AsyncStream<NotificationEvent> {
        // Feasibility spike pending: until the ingest questions in the PRD
        // are answered on a real machine, System Mirror probes honestly and
        // streams nothing.
        AsyncStream { $0.finish() }
    }
}
