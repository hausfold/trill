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
    /// Turns "you're back" into one card — see CatchUpReporter. Fed by
    /// `PresenceSentinel`, which is also what tells the repository whether a
    /// banner was drawn at anybody.
    private let catchUp: CatchUpReporter
    private var deliveryTask: Task<Void, Never>?
    private var rulesWatcher: RulesWatcher
    /// Follows `persistHistory` — see `applyPersistence`.
    private var persistenceObserver: AnyCancellable?
    /// Follows `shyWhenWatched`, so a flipped switch re-renders what's up.
    private var shynessObserver: AnyCancellable?
    /// Armed pollers for parked asks that named a `--until` resolver. Held
    /// here so `stop()` can cancel them — a resolver outliving the daemon
    /// would be a process trill can no longer report on.
    private var resolutionMonitor: ResolutionMonitor?
    /// The daemon side of `trill inbox` and of a digest card's click — set
    /// by the app delegate, which owns the windows. The scope says which
    /// slice of history the window is for.
    var onOpenInbox: ((InboxScope) -> Void)?
    /// The same door for trill's own Settings, on a named pane. Reached by a
    /// "Silence Native Banners" click whose apps macOS lists no row for —
    /// nothing to walk through, so the Banners pane is the answer.
    var onOpenSettings: ((SettingsPane) -> Void)?
    /// The live signal behind every inbox window: which database to read,
    /// when something landed, what is still on the ledge. Built here because
    /// this is the only place that sees all three.
    let inboxFeed: InboxFeed

    private static let log = Logger(subsystem: "com.hausfold.trill", category: "runtime")

    init() {
        let settings = AppSettings()
        self.settings = settings

        let database = settings.persistHistory ? AppDatabase(url: AppPaths.databaseFile) : nil
        self.database = database
        inboxFeed = InboxFeed(database: database)

        // Rules hot-reload: the watcher owns the current RuleSet; the
        // repository asks for a fresh engine per event, so an edited
        // rules.json applies to the very next notification.
        let watcher = RulesWatcher(file: AppPaths.rulesFile)
        rulesWatcher = watcher
        // The presence flag is read once per event, off the main actor: a
        // banner drawn at a locked screen is recorded unread, which is what
        // makes both the inbox's count and the catch-up card's tally mean
        // "trill never put this in front of you".
        let presence = PresenceSentinel.shared.flag
        // Read, never written. The reader applies the `focusAware` switch
        // itself and hands the engine `.off` while it is off, so a trill that
        // has been told not to care decides exactly what it decided before
        // this existed. It is the sentinel's reader so Settings and the
        // ingest path can never disagree about what macOS is doing.
        let focus = FocusSentinel.shared.reader
        repository = EventRepository(
            policy: { PolicyEngine(ruleSet: watcher.current()) },
            database: database,
            presence: { presence.isPresent },
            focus: { focus.effective() }
        )
        // Read live, so a switch flipped in Settings — or typed into
        // config.json — applies to the next absence rather than the next
        // launch. Where it reads history from is wired in `start()`, along
        // with where its card goes.
        catchUp = CatchUpReporter(enabled: { ConfigFileStore.shared.current().catchUpCard })

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
                AppRuntime.listedApps(rules: watcher.current())
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
        actionRouter.openSettings = { [weak self] pane in self?.onOpenSettings?(pane) }
        digests.onCard = { [queue] card in queue.enqueue(card) }
        digests.start()

        // The other composed-by-trill card, and the same rule: straight to
        // the queue, never back through the repository. `self.database` is
        // read at call time rather than captured, because the setting behind
        // it is live (`applyPersistence`).
        catchUp.database = { [weak self] in self?.database }
        catchUp.onCard = { [queue] card in queue.enqueue(card) }
        // Presence is started *after* the reporter is wired: the launch is
        // itself a signal, and on a Mac that was locked when trill last quit
        // it can hand back a window on the spot.
        PresenceSentinel.shared.onReturn = { [weak self] window in
            self?.catchUp.report(returned: window)
        }
        PresenceSentinel.shared.start()

        // The file is the truth for this one too, and it is the setting where
        // that matters most: switching history off — in Settings or by typing
        // it into config.json — has to stop the writing now, not at the next
        // launch. `@Published` delivers the new value in `willSet`, so the
        // published property itself is still the old one here; use what came
        // through.
        persistenceObserver = settings.$persistHistory.sink { [weak self] enabled in
            Task { @MainActor in self?.applyPersistence(enabled) }
        }

        // Same shape, and the same reason: the file is the truth for shyness
        // too, so typing `"shyWhenWatched": false` has to un-redact the cards
        // that are on screen right now. The sentinel re-reads the switch
        // itself — this only tells it when to look. Deferred a turn because
        // `@Published` delivers in `willSet`, before the write reaches the
        // config store the sentinel asks.
        shynessObserver = settings.$shyWhenWatched.sink { _ in
            Task { @MainActor in ScreenWatchSentinel.shared.refresh() }
        }

        deliveryTask = Task { [repository, queue, digests, askBroker, inboxFeed] in
            for await delivered in await repository.deliveries() {
                // Every delivered event is already persisted (the repository
                // writes before it fans out), so this is the moment an open
                // inbox can see it — whatever the decision was. A `digest`
                // event lands in the inbox an hour before its card does, and
                // that is the point: the tally is the *banner's* schedule,
                // not the history's.
                inboxFeed.noteDelivery()
                // Resolution first, and regardless of delivery: an event that
                // answers a question answers it even when a rule sends the
                // event itself to the inbox. "PR merged" may well be a quiet
                // event in someone's rules; the fin it clears is not.
                queue.resolve(keys: delivered.event.resolves)
                switch delivered.decision {
                case .banner(let display):
                    // Claimed before it is drawn: past this point the ask
                    // waits on the user for as long as they take, and the
                    // broker's claim watchdog stands down.
                    askBroker.claim(id: delivered.event.id)
                    queue.enqueue(delivered.event, on: display)
                case .ledge(let display):
                    // A fin is on screen and answerable, so the claim is a
                    // banner's claim: the asker waits for as long as the user
                    // takes, and the broker's watchdog stands down. What a
                    // Focus changes is that the question never interrupted —
                    // not that it went unasked.
                    askBroker.claim(id: delivered.event.id)
                    queue.park(delivered.event, on: display)
                case .digest(let name):
                    // Counted now, drawn on the hour. The event itself was
                    // already persisted by the repository — the scheduler
                    // keeps a tally, never a copy.
                    askBroker.unshown(id: delivered.event.id)
                    // A tick was never persisted (`isProgressTick`), so
                    // counting it would put a number on the digest card that
                    // its own inbox scope can't show. One build is one line,
                    // and it gets it when it ends.
                    if !delivered.event.isProgressTick {
                        digests.accumulate(delivered.event, digest: name)
                    }
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
                listedApps: { AppRuntime.listedApps(rules: rulesWatcher.current()) },
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
            // Same "always probed" reasoning: the Sources row has to be able
            // to say *why* the calendar is quiet — switched off, or granted
            // write-only — and it can only know that from this provider's
            // health. The probe never asks macOS for anything; the grant is
            // requested where the switch is flipped.
            await repository.supervise(CalendarProvider())
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
        inboxFeed.database = database
        Task { [repository] in await repository.setDatabase(database) }
        Self.log.info("history persistence \(enabled ? "on" : "off", privacy: .public)")
    }

    func stop() {
        // Stamps the departure as it goes, so a Mac locked at 23:00 that
        // reboots overnight still opens tomorrow's window at 23:00.
        PresenceSentinel.shared.stop()
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
            // Questions only, on the way to disk: the ledge also holds the
            // fin of a *running job* now, and that one is worth nothing after
            // a relaunch — the build it was reporting died with the daemon,
            // and a bar frozen at 40% that nothing will ever finish is the
            // one thing a restored fin must not be. It is also not history:
            // a tick is never written to the events table either.
            let questions = entries.filter { !$0.event.isProgressTick }
            self?.database?.saveLedge(questions.map {
                AppDatabase.StoredParked(event: $0.event, coalescedCount: $0.coalescedCount)
            })
            // Resolvers get the whole ledge: `--until` is a property of the
            // event, not of its kind, so a job that named one is polled like
            // a question that did.
            monitor.reconcile(entries)
            // The inbox draws a fin beside the asks that are still on the
            // ledge, so an eviction has to reach it: the ask that yielded is
            // now only here, and looking identical to one still parked would
            // be the inbox lying about where the question lives.
            self?.inboxFeed.noteParked(Set(questions.map(\.event.id)))
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

    /// The one router in the app, lent to the inbox so a pill clicked there
    /// goes exactly where the same pill on a banner would — including the
    /// capability checks. The inbox draws no `reply` pills (see
    /// `InboxList.pills`), so nothing here can answer a caller that has gone.
    var inboxActionRouter: ActionRouter { actionRouter }

    /// The bundle ids the current rules name — what both `trill doctor` and
    /// the Settings audit mean by "a listed app". Read live, so an edited
    /// rules.json is reflected without a restart.
    var listedApps: [String] {
        Self.listedApps(rules: rulesWatcher.current())
    }

    /// One answer for every caller, because there are three of them and the
    /// helper walks whatever they agree on. Both inputs are read at call time:
    /// an edited rules.json or a flipped calendar switch changes the next
    /// audit without a restart.
    /// `nonisolated` because two of the three callers are `@Sendable` closures
    /// the supervisor runs off the main actor; everything it touches is either
    /// pure or already queue-guarded.
    nonisolated static func listedApps(rules: RuleSet) -> [String] {
        NotificationSettingsAudit.listedBundleIDs(
            in: rules,
            calendarSourceEnabled: ConfigFileStore.shared.current().calendarEnabled
        )
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
