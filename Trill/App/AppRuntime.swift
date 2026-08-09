import AppKit
import SwiftUI
import os.log

/// Composition root: builds the pipeline (providers → repository → policy →
/// queue → compositor), owns every long-lived object, and is the only place
/// that knows the whole shape.
@MainActor
final class AppRuntime {
    let settings: AppSettings
    private let database: AppDatabase?
    private let repository: EventRepository
    private let queue: BannerQueue
    private let windowSystem: BannerWindowSystem
    private var deliveryTask: Task<Void, Never>?
    private var rulesWatcher: RulesWatcher

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

        queue = BannerQueue()
        // The router needs the listed apps for the same reason `trill doctor`
        // does: a "Silence Native Banners" click that can't tell which apps it
        // was about must fall back to the ones the rules name, not the Mac.
        windowSystem = BannerWindowSystem(
            queue: queue,
            actionRouter: ActionRouter(listedApps: {
                NotificationSettingsAudit.listedBundleIDs(in: watcher.current())
            })
        )
    }

    func start() {
        windowSystem.start()
        rulesWatcher.start()

        deliveryTask = Task { [repository, queue] in
            for await delivered in await repository.deliveries() {
                if case .banner = delivered.decision {
                    queue.enqueue(delivered.event)
                }
                // inboxOnly / digest events were already persisted by the
                // repository; digest flushing is milestone 2.
            }
        }

        Task { [repository, rulesWatcher, weak self] in
            // `trill doctor` with no app list audits whatever the current
            // rules name — read live, so an edited rules.json changes the
            // next audit without a restart.
            await repository.supervise(SocketProvider(listedApps: {
                NotificationSettingsAudit.listedBundleIDs(in: rulesWatcher.current())
            }))
            // Always probed, regardless of the toggle: Settings gates the
            // toggle itself on Full Disk Access being granted, which it can
            // only know by reading this provider's health.
            await repository.supervise(SystemMirrorProvider())
            await self?.reconcileSystemMirrorSetting()
        }

        database?.prune(olderThan: 30 * 24 * 3600)
        Self.log.info("trill runtime started")
    }

    func stop() {
        deliveryTask?.cancel()
        windowSystem.stop()
        Task { [repository] in await repository.shutdown() }
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
        source?.cancel()
        source = nil
        if watchedFD >= 0 { close(watchedFD); watchedFD = -1 }

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
