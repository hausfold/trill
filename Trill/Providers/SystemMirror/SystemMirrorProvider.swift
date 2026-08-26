import AppKit
import Foundation
import os.log

/// **System Mirror — experimental.** The read-only-mirror move applied to
/// notifications: read Apple-owned state directly, read-only, and own only the
/// presentation. The source is the `usernoted` daemon's private store
/// (`~/Library/Group Containers/group.com.apple.usernoted/db2/db`), which —
/// unlike Messages' `chat.db` — is an undocumented implementation detail that
/// can change shape on any macOS update.
///
/// Quarantine rules (enforced in `UsernotedStore`, documented in
/// ARCHITECTURE.md):
///   - opened `SQLITE_OPEN_READONLY`, never a write-capable flag;
///   - schema probed before every session — drift disables the provider with
///     a reason, it never guesses;
///   - usernoted types stop at this directory: everything is mapped to
///     `NotificationEvent` by `SystemMirrorMapper` before leaving;
///   - fully useful app without it. Off by default; requires Full Disk
///     Access, surfaced honestly in settings.
///
/// **What the M3 spike measured, and what it costs you.** usernoted does not
/// write a row when it delivers a notification — it batches, and the row
/// becomes visible to a reader **~5.1 s later** (measured twice on macOS 26,
/// 5137 ms and 5143 ms, against a `delivered_date` accurate to ~65 ms of the
/// real event). Nothing can close that gap from outside the daemon: watching
/// the write-ahead log fires at the same instant the row appears, so the
/// watcher below buys correctness over a poll, not latency. A mirrored card is
/// therefore *five seconds late by construction*, which is fine for the thing
/// it is for — one banner instead of two, in trill's own vocabulary — and
/// wrong for anything time-critical. Say the number; don't design around it.
///
/// The delivery *timestamp* is exact, so a card drawn late still says when
/// the thing actually happened.
struct SystemMirrorProvider: NotificationProvider {
    let name = "system-mirror"
    let capabilities = ProviderCapabilities(
        canOpenSource: true,
        canDismissAtSource: false,
        experimental: true
    )

    static let log = Logger(subsystem: "com.hausfold.trill", category: "system-mirror")

    private let storePath: String
    /// Read from the config file's store rather than `AppSettings`: the
    /// supervisor calls this off the main actor, and the toggle's only job
    /// here is yes/no.
    private let enabled: @Sendable () -> Bool
    /// Which apps the user ticked, or nil when they never narrowed it. Read
    /// from the file on every drain for the same reason `enabled` is: a tick
    /// has to change what the *next* notification does, not what the next
    /// launch does.
    private let allowedApps: @Sendable () -> Set<String>?

    init(
        storePath: String = UsernotedStore.defaultPath(),
        enabled: @escaping @Sendable () -> Bool = {
            ConfigFileStore.shared.current().systemMirrorEnabled
        },
        allowedApps: @escaping @Sendable () -> Set<String>? = {
            ConfigFileStore.shared.current().systemMirrorApps.map(Set.init)
        }
    ) {
        self.storePath = storePath
        self.enabled = enabled
        self.allowedApps = allowedApps
    }

    /// Deliberately *not* gated on the toggle: Settings decides whether the
    /// switch may be flipped at all by reading this health, and it can only
    /// learn "Full Disk Access is missing" from a probe that ran anyway.
    /// Nothing here asks macOS for a permission — it opens a file or it
    /// doesn't.
    func probe() async -> ProviderHealth {
        let store = UsernotedStore(path: storePath)
        do {
            try store.open()
            store.close()
            return .ready
        } catch let error as UsernotedStore.OpenError {
            switch error {
            case .unreadable(let reason), .schemaDrift(let reason):
                return .unavailable(reason: reason)
            }
        } catch {
            return .unavailable(reason: "usernoted store unreadable")
        }
    }

    func events() async -> AsyncStream<NotificationEvent> {
        AsyncStream { continuation in
            let watcher = UsernotedWatcher(
                storePath: storePath,
                enabled: enabled,
                allowedApps: allowedApps,
                yield: { continuation.yield($0) },
                finish: { continuation.finish() }
            )
            watcher.start()
            continuation.onTermination = { _ in watcher.stop() }
        }
    }
}

/// The moving parts: one read-only connection, one high-water mark, and one
/// file-system source watching usernoted's write-ahead log.
///
/// Serialized on a single queue the way `CalendarWatcher` and
/// `ConfigFileStore` are, because the same three callers arrive at once —
/// the WAL source on whatever thread libdispatch likes, the sweep timer, and
/// the stream's termination handler.
final class UsernotedWatcher: @unchecked Sendable {
    /// How long to let a commit settle before reading. usernoted's flush is
    /// one transaction, but the file event fires on the write, not the
    /// commit, and a read that lands mid-transaction simply sees the old
    /// snapshot — which would then wait for the *next* notification to be
    /// noticed. Small enough to be invisible against the 5 s the daemon
    /// already costs us.
    static let settle: TimeInterval = 0.2
    /// Belt to the WAL source's braces. A checkpoint replaces the `-wal`
    /// file, and although the source re-arms on that, a sweep means a missed
    /// re-arm costs one interval rather than every notification after it.
    static let sweepInterval: TimeInterval = 15
    /// A row already this old when first seen is recorded, not drawn. It
    /// exists for the case where a sweep finds a backlog — a Mac that woke up
    /// to a queue — and the honest thing is to not fire ten stale banners.
    static let staleAfter: TimeInterval = 5 * 60

    private let queue = DispatchQueue(label: "com.hausfold.trill.system-mirror")
    private let storePath: String
    private let enabled: @Sendable () -> Bool
    private let allowedApps: @Sendable () -> Set<String>?
    private let yield: @Sendable (NotificationEvent) -> Void
    private let finish: @Sendable () -> Void

    private let store: UsernotedStore
    private var watermark: Int64 = 0
    private var source: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var sweep: DispatchSourceTimer?
    private var stopped = false
    /// Localized app names, asked of `NSWorkspace` once each. The mapper is
    /// pure and takes the answer as an argument; this is the impure side.
    private var appNames: [String: String] = [:]

    init(
        storePath: String,
        enabled: @escaping @Sendable () -> Bool,
        allowedApps: @escaping @Sendable () -> Set<String>? = { nil },
        yield: @escaping @Sendable (NotificationEvent) -> Void,
        finish: @escaping @Sendable () -> Void
    ) {
        self.storePath = storePath
        self.enabled = enabled
        self.allowedApps = allowedApps
        self.yield = yield
        self.finish = finish
        self.store = UsernotedStore(path: storePath)
    }

    func start() {
        queue.async { [self] in
            do {
                try store.open()
                // Start from *now*. Whatever is still sitting in Notification
                // Center was already shown once; replaying it on every launch
                // would make turning the mirror on feel like a flood.
                watermark = try store.latestRecordID()
            } catch {
                SystemMirrorProvider.log.info(
                    "system mirror could not start: \(String(describing: error), privacy: .public)"
                )
                finish()
                return
            }
            SystemMirrorProvider.log.info(
                "system mirror watching from record \(self.watermark, privacy: .public)"
            )
            watch()
            armSweep()
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            source?.cancel()
            source = nil
            sweep?.cancel()
            sweep = nil
            store.close()
        }
    }

    // MARK: - Reading

    /// One pass. Advances the watermark whether or not anything is drawn, so
    /// a mirror that is switched off still comes back on at the present
    /// moment rather than replaying everything it missed.
    private func drain() {
        guard !stopped, store.isOpen else { return }
        let records: [UsernotedRecord]
        do {
            records = try store.records(after: watermark)
        } catch {
            // A read that fails after a successful open is the grant being
            // taken away underneath us (an ad-hoc rebuild re-pins the cdhash)
            // or the store being replaced. Finish, and let the supervisor
            // re-probe and say why.
            SystemMirrorProvider.log.info(
                "system mirror read failed: \(String(describing: error), privacy: .public)"
            )
            store.close()
            finish()
            return
        }
        guard let last = records.last else { return }
        watermark = max(watermark, last.recordID)
        SystemMirrorProvider.log.info(
            "system mirror read \(records.count, privacy: .public) row(s) up to \(last.recordID, privacy: .public)"
        )

        guard enabled() else { return }
        let now = Date()
        let running = Bundle.main.bundleIdentifier
        // Read once per drain, not per row: it's a file read, and every row in
        // one batch is being judged against the same answer anyway.
        let allowed = allowedApps()
        for record in records {
            guard now.timeIntervalSince(record.deliveredAt) < Self.staleAfter else { continue }
            // Unticked apps are dropped *after* the watermark moved, so
            // ticking one later starts it from the present rather than
            // replaying everything it missed while it was off.
            guard SystemMirrorMapper.isAllowed(record.bundleID, allowing: allowed) else { continue }
            guard let event = SystemMirrorMapper.event(
                for: record,
                appName: appName(for: record.bundleID),
                runningBundleID: running
            ) else { continue }
            // Ids and sources only — a mirrored notification is someone's
            // messages.
            SystemMirrorProvider.log.debug(
                "mirrored \(event.id, privacy: .public) from \(event.source, privacy: .public)"
            )
            yield(event)
        }
        // A full batch means there is more behind it; come straight back
        // rather than waiting for the next file event.
        if records.count == UsernotedStore.batchLimit {
            queue.async { [self] in drain() }
        }
    }

    private func appName(for bundleID: String) -> String? {
        let slug = SystemMirrorMapper.source(for: bundleID)
        if let cached = appNames[slug] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: slug) else {
            return nil
        }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        appNames[slug] = name
        return name
    }

    // MARK: - Watching

    private func watch() {
        source?.cancel()
        source = nil

        let wal = UsernotedStore.walPath(for: storePath)
        let fd = Darwin.open(wal, O_EVTONLY)
        guard fd >= 0 else {
            // No write-ahead log yet: the sweep is the whole mechanism until
            // one appears. Not fatal — a quiet Mac genuinely has none.
            watchedFD = -1
            return
        }
        watchedFD = fd
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let replaced = src.data.contains(.delete) || src.data.contains(.rename)
            queue.asyncAfter(deadline: .now() + Self.settle) { [weak self] in
                self?.drain()
            }
            // A checkpoint replaces the file; the old descriptor now points
            // at nothing anyone will write to again.
            if replaced { watch() }
        }
        src.setCancelHandler { [fd] in if fd >= 0 { close(fd) } }
        src.resume()
        source = src
    }

    private func armSweep() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.sweepInterval, repeating: Self.sweepInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if watchedFD < 0 { watch() }
            drain()
        }
        timer.resume()
        sweep = timer
    }
}
