import AppKit
import Combine
import SwiftUI
import os.log

/// Composition root: builds the pipeline (providers → repository → policy →
/// queue → compositor), owns every long-lived object, and is the only place
/// that knows the whole shape.
@MainActor
final class AppRuntime {
    let settings: AppSettings
    private var database: AppDatabase?
    private let repository: EventRepository
    private let queue: BannerQueue
    private let actionRouter: ActionRouter
    /// Who is blocked on a `trill ask` right now. Lives here because it is
    /// the one thing both ends of that round trip touch: the socket provider
    /// registers a caller, the action router answers it, and this file is the
    /// only place that has seen both.
    private let askBroker: AskBroker
    private let windowSystem: BannerWindowSystem
    /// Drains `delivery: digest` into one card an hour — see DigestScheduler.
    private let digests: DigestScheduler
    private var deliveryTask: Task<Void, Never>?
    private var rulesWatcher: RulesWatcher
    /// Follows `persistHistory` — see `applyPersistence`.
    private var persistenceObserver: AnyCancellable?
    /// Armed pollers for parked asks that named a `--until` resolver. Held
    /// here so `stop()` can cancel them — a resolver outliving the daemon
    /// would be a process trill can no longer report on.
    private var resolutionMonitor: ResolutionMonitor?
    /// The daemon side of `trill inbox` and of a digest card's click — set
    /// by the app delegate, which owns the windows. The scope says which
    /// slice of history the window is for.
    var onOpenInbox: ((InboxScope) -> Void)?

    private static let log = Logger(subsystem: "com.hausfold.trill", category: "runtime")

    init() {
        let settings = AppSettings()
        self.settings = settings

        database = settings.persistHistory ? AppDatabase(url: AppPaths.databaseFile) : nil

        // Rules hot-reload: the watcher owns the current RuleSet; the
        // repository asks for a fresh engine per event, so an edited
        // rules.json applies to the very next notification.
        let watcher = RulesWatcher(file: AppPaths.rulesFile)
        rulesWatcher = watcher
        repository = EventRepository(
            policy: { PolicyEngine(ruleSet: watcher.current()) },
            database: database
        )

        let queue = BannerQueue()
        self.queue = queue
        // Quiet hours are read live for the same reason every other rules
        // question is: an edit to rules.json moves the next flush, not the
        // next launch.
        digests = DigestScheduler(quietHours: { watcher.current().quietHours })
        // Retraction goes through the queue like every other takedown, so a
        // question whose asker hung up leaves the screen the same way one the
        // user dismissed does — panels stay disposable, the queue stays the
        // truth.
        let askBroker = AskBroker { id in
            Task { @MainActor in queue.dismiss(id: id) }
        }
        self.askBroker = askBroker
        // The router needs the listed apps for the same reason `trill doctor`
        // does: a "Silence Native Banners" click that can't tell which apps it
        // was about must fall back to the ones the rules name, not the Mac.
        actionRouter = ActionRouter(
            listedApps: {
                NotificationSettingsAudit.listedBundleIDs(in: watcher.current())
            },
            askBroker: askBroker
        )
        windowSystem = BannerWindowSystem(queue: queue, actionRouter: actionRouter)
        // The other half of the round trip: a banner that goes away without
        // being answered still owes its caller an exit code. Resolution comes
        // through here too — `resolve` takes a fin down by dismissing it —
        // so a question answered by another process unblocks its asker as
        // surely as one waved away by hand.
        queue.onDropped = { events in
            events.forEach { askBroker.abandon(id: $0.id) }
        }
    }

    func start() {
        windowSystem.start()
        rulesWatcher.start()
        wireLedge()
        // Both inbox doors — `trill inbox` over the socket, a digest card's
        // click — land on the same delegate. Set here rather than in `init`
        // because a closure over `self` needs a fully-initialized one.
        actionRouter.openInbox = { [weak self] scope in self?.onOpenInbox?(scope) }
        digests.onCard = { [queue] card in queue.enqueue(card) }
        digests.start()

        // The file is the truth for this one too, and it is the setting where
        // that matters most: switching history off — in Settings or by typing
        // it into config.json — has to stop the writing now, not at the next
        // launch. `@Published` delivers the new value in `willSet`, so the
        // published property itself is still the old one here; use what came
        // through.
        persistenceObserver = settings.$persistHistory.sink { [weak self] enabled in
            Task { @MainActor in self?.applyPersistence(enabled) }
        }

        deliveryTask = Task { [repository, queue, digests, askBroker] in
            for await delivered in await repository.deliveries() {
                // Resolution first, and regardless of delivery: an event that
                // answers a question answers it even when a rule sends the
                // event itself to the inbox. "PR merged" may well be a quiet
                // event in someone's rules; the fin it clears is not.
                queue.resolve(keys: delivered.event.resolves)
                switch delivered.decision {
                case .banner:
                    // Claimed before it is drawn: past this point the ask
                    // waits on the user for as long as they take, and the
                    // broker's claim watchdog stands down.
                    askBroker.claim(id: delivered.event.id)
                    queue.enqueue(delivered.event)
                case .digest(let name):
                    // Counted now, drawn on the hour. The event itself was
                    // already persisted by the repository — the scheduler
                    // keeps a tally, never a copy.
                    askBroker.unshown(id: delivered.event.id)
                    digests.accumulate(delivered.event, digest: name)
                case .inboxOnly, .drop:
                    // A *question* held back this way is one nobody will ever
                    // see, so its caller is told now rather than left blocked
                    // on a banner quiet hours already swallowed.
                    askBroker.unshown(id: delivered.event.id)
                }
            }
        }

        Task { [repository, rulesWatcher, askBroker, weak self] in
            // `trill doctor` with no app list audits whatever the current
            // rules name — read live, so an edited rules.json changes the
            // next audit without a restart.
            await repository.supervise(SocketProvider(
                listedApps: {
                    NotificationSettingsAudit.listedBundleIDs(in: rulesWatcher.current())
                },
                openInbox: { [weak self] asksOnly in
                    Task { @MainActor in self?.onOpenInbox?(asksOnly ? .asks : .all) }
                },
                resolve: { [weak self] keys, done in
                    Task { @MainActor in
                        done(self?.queue.resolve(keys: keys) ?? 0)
                    }
                },
                askBroker: askBroker
            ))
            // Always probed, regardless of the toggle: Settings gates the
            // toggle itself on Full Disk Access being granted, which it can
            // only know by reading this provider's health.
            await repository.supervise(SystemMirrorProvider())
            // Also always probed: the Settings row shows *why* the bridge is
            // off (no config, taken port) even before the toggle goes on.
            await repository.supervise(GitHubWebhookProvider(
                enabled: { ConfigFileStore.shared.current().githubBridgeEnabled }
            ))
            await self?.reconcileSystemMirrorSetting()
        }

        database?.prune(olderThan: 30 * 24 * 3600)
        Self.log.info("trill runtime started")
    }

    /// Open or drop trill's own database to match the setting. Idempotent:
    /// `@Published` fires on every assignment, including the ones that don't
    /// change anything.
    private func applyPersistence(_ enabled: Bool) {
        guard enabled != (database != nil) else { return }
        let database = enabled ? AppDatabase(url: AppPaths.databaseFile) : nil
        self.database = database
        Task { [repository] in await repository.setDatabase(database) }
        Self.log.info("history persistence \(enabled ? "on" : "off", privacy: .public)")
    }

    func stop() {
        deliveryTask?.cancel()
        resolutionMonitor?.stop()
        digests.stop()
        windowSystem.stop()
        Task { [repository] in await repository.shutdown() }
    }

    /// Everything that happens to the ledge besides drawing it: mirror it to
    /// disk, keep the resolvers armed, and hang last session's fins back up.
    ///
    /// All three ride the one non-compositor callback, and it is set *before*
    /// the restore, so the first list — already pruned of anything stale —
    /// is written straight back and its resolvers armed immediately.
    ///
    /// No database means no ledge across restarts: with history off nothing
    /// in this app writes to disk, and quietly making an exception for asks
    /// would be trill keeping notification content the user switched off.
    /// That setting is live (`applyPersistence`), so the mirror asks for the
    /// database each time rather than holding one. Resolvers still run either
    /// way — they need no history, only a fin.
    private func wireLedge() {
        let monitor = ResolutionMonitor(
            rules: { [rulesWatcher] in rulesWatcher.current() },
            resolve: { [weak self] key in _ = self?.queue.resolve(keys: [key]) }
        )
        resolutionMonitor = monitor

        // `self.database`, read at call time rather than captured: history
        // can be switched off (or back on) while trill runs, and a captured
        // handle would keep mirroring the ledge into a database the user just
        // turned off.
        queue.onParkedForResolution = { [weak self] entries in
            self?.database?.saveLedge(entries.map {
                AppDatabase.StoredParked(event: $0.event, coalescedCount: $0.coalescedCount)
            })
            monitor.reconcile(entries)
        }

        guard let database else { return }
        queue.restoreParked(
            database.parkedLedge(maxAge: BannerQueue.parkedLifetime)
                .map { ($0.event, $0.coalescedCount) }
        )
    }

    /// macOS revokes a Full Disk Access grant on its own when it can no
    /// longer match the running build against the one it granted (an ad-hoc
    /// signature pins the cdhash, so any rebuild does it). Left alone, the
    /// app would keep claiming System Mirror is on while the provider sits
    /// dead — so believe the probe, not the stored flag.
    private func reconcileSystemMirrorSetting() async {
        guard settings.systemMirrorEnabled else { return }
        guard case .unavailable(let reason)? = await repository.providerHealth["system-mirror"]
        else { return }
        settings.systemMirrorEnabled = false
        Self.log.info("system mirror disabled on launch: \(reason, privacy: .public)")
    }

    func providerStatusSnapshot() async -> [String: String?] {
        let health = await repository.providerHealth
        return health.mapValues { health -> String? in
            if case .unavailable(let reason) = health { return reason }
            return nil
        }
    }

    var inboxDatabase: AppDatabase? { database }

    /// The bundle ids the current rules name — what both `trill doctor` and
    /// the Settings audit mean by "a listed app". Read live, so an edited
    /// rules.json is reflected without a restart.
    var listedApps: [String] {
        NotificationSettingsAudit.listedBundleIDs(in: rulesWatcher.current())
    }
}

/// Loads `~/.config/trill/rules.json` and reloads it when it changes.
/// A malformed file logs and keeps the last good rules — a typo in a rule
/// must never turn every banner off.
final class RulesWatcher: @unchecked Sendable {
    private let file: URL
    private let queue = DispatchQueue(label: "com.hausfold.trill.rules")
    private var ruleSet: RuleSet = .empty
    private var source: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private static let log = Logger(subsystem: "com.hausfold.trill", category: "rules")

    init(file: URL) {
        self.file = file
    }

    func current() -> RuleSet {
        queue.sync { ruleSet }
    }

    func start() {
        queue.sync {
            load()
            watch()
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else {
            ruleSet = .empty
            return
        }
        do {
            ruleSet = try JSONDecoder.trill.decode(RuleSet.self, from: data)
            Self.log.info("loaded \(self.ruleSet.rules.count) rule(s)")
        } catch {
            Self.log.error("rules.json invalid — keeping previous rules: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func watch() {
        // The fd belongs to the cancel handler, which captured it and runs on
        // this queue after we return — closing it here would hand `open` the
        // same number back and let the stale handler close the new one. See
        // the note in ConfigFileStore.watch().
        source?.cancel()
        source = nil
        watchedFD = -1

        // Editors replace the file (rename+write), so watch for both and
        // re-arm on delete.
        watchedFD = open(file.path, O_EVTONLY)
        guard watchedFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedFD,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.load()
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self?.watch()
            }
        }
        src.setCancelHandler { [fd = watchedFD] in if fd >= 0 { close(fd) } }
        src.resume()
        source = src
    }
}
