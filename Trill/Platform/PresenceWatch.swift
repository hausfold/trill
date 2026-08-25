import AppKit
import Foundation
import os.log

// MARK: - The signals

/// Everything macOS says that bears on "is anyone in front of this Mac".
///
/// **Pushed, not polled** — the opposite of `ScreenWatch`, and worth saying
/// out loud because the two look like the same kind of question. Nothing
/// reports screen capture, so shyness has to poll; lock, unlock, sleep and
/// wake are all posted, so this never reads the system at all. It listens.
enum PresenceSignal: String, Sendable {
    /// `com.apple.screenIsLocked` — the lock screen came up.
    case locked
    /// `com.apple.screenIsUnlocked` — someone typed the password.
    case unlocked
    /// The Mac is going to sleep. Not the same as locked: a Mac that sleeps
    /// with no password set wakes straight onto the desktop.
    case slept
    /// The Mac woke. Presence only when nothing locked it — see `PresenceLog`.
    case woke
    /// Another account took the session (fast user switching).
    case switchedAway
    /// This account's session came back.
    case switchedBack
    /// trill started.
    case launched
    /// trill is quitting.
    case quitting
}

// MARK: - The state machine

/// Who trill believes is here, and since when.
///
/// Pure and persistable: the whole "were you away, and from when" decision is
/// this struct, so it is tested without a screen, a lock, or a Mac — and it
/// survives a restart, which is the case that matters most. A Mac locked at
/// 23:00 that reboots at 03:00 and is logged into at 08:00 has to report the
/// four hours of traffic between the lock and the reboot; nothing in memory
/// can know that.
struct PresenceLog: Equatable, Sendable {
    /// The last moment trill knew somebody was here. While away, this is the
    /// instant they left — the `since` a catch-up window opens at.
    var lastPresent: Date
    /// Whether we currently believe nobody is here.
    var isAway: Bool
    /// Whether the screen is locked specifically, as opposed to merely
    /// asleep. This is the difference between a Mac that wakes onto a lock
    /// screen and one that wakes onto the desktop: waking is presence for the
    /// second and nothing at all for the first.
    var isLocked: Bool

    init(lastPresent: Date = .now, isAway: Bool = false, isLocked: Bool = false) {
        self.lastPresent = lastPresent
        self.isAway = isAway
        self.isLocked = isLocked
    }

    /// Feed one signal in. Returns the absence that just ended, when one did:
    /// `lastPresent...at`, unfiltered — how long an absence has to be to earn
    /// a card is the card's business (`CatchUpCard.window`), not the log's.
    ///
    /// Going away is **idempotent in the timestamp**: the first departure
    /// wins. Locking at 23:00 and then sleeping at 23:30 is one absence that
    /// began at 23:00, and a second stamp would silently shorten the window
    /// past everything that arrived in the first half hour.
    mutating func note(_ signal: PresenceSignal, at instant: Date) -> ClosedRange<Date>? {
        switch signal {
        case .locked:
            isLocked = true
            return away(at: instant)
        case .slept, .switchedAway, .quitting:
            return away(at: instant)
        case .unlocked, .switchedBack:
            isLocked = false
            return present(at: instant)
        case .woke:
            // A wake onto a lock screen is not a return — the card would be
            // drawn, timed out and gone before the password was typed. The
            // unlock that follows is the return. A Mac with no lock at all
            // never posts one, and for that Mac waking *is* the return.
            guard !isLocked else { return nil }
            return present(at: instant)
        case .launched:
            // Launching is presence — but only ends an absence that a
            // previous run recorded. A relaunch while somebody was sitting
            // here (a crash, an update) ends nothing and reports nothing.
            return present(at: instant)
        }
    }

    private mutating func away(at instant: Date) -> ClosedRange<Date>? {
        guard !isAway else { return nil }
        isAway = true
        lastPresent = instant
        return nil
    }

    private mutating func present(at instant: Date) -> ClosedRange<Date>? {
        defer {
            isAway = false
            lastPresent = instant
        }
        guard isAway, lastPresent <= instant else { return nil }
        return lastPresent...instant
    }
}

// MARK: - Persistence

/// Where the log lives across launches: `UserDefaults`, with the window
/// frames and the one-shot flags.
///
/// Not `config.json`, which is the truth for *switches* — this is not a
/// setting, it is one timestamp about trill's own lifecycle, and a user
/// hand-editing it would be editing a fact rather than a preference. It holds
/// no notification content of any kind: when it was, never what it was.
struct PresenceStore {
    private let defaults: UserDefaults

    private enum Keys {
        static let lastPresent = "presence.lastPresent"
        static let away = "presence.away"
        static let locked = "presence.locked"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The stored log, or nil on a Mac that has never run this build — which
    /// is not an absence and must not produce a card for all of history.
    func load() -> PresenceLog? {
        let stamp = defaults.double(forKey: Keys.lastPresent)
        guard stamp > 0 else { return nil }
        return PresenceLog(
            lastPresent: Date(timeIntervalSince1970: stamp),
            isAway: defaults.bool(forKey: Keys.away),
            isLocked: defaults.bool(forKey: Keys.locked)
        )
    }

    func save(_ log: PresenceLog) {
        defaults.set(log.lastPresent.timeIntervalSince1970, forKey: Keys.lastPresent)
        defaults.set(log.isAway, forKey: Keys.away)
        defaults.set(log.isLocked, forKey: Keys.locked)
    }
}

// MARK: - The live flag

/// "Is anybody actually looking at this screen right now", readable from any
/// task.
///
/// It exists because the answer is needed off the main actor: the repository
/// stamps every delivered event read or unread as it lands (see
/// `AppDatabase.insert`), and *drawn at a locked screen* is not read. One
/// lock around one Bool, rather than an actor hop on the ingest path.
final class PresenceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var present: Bool

    init(present: Bool = true) {
        self.present = present
    }

    var isPresent: Bool {
        lock.lock()
        defer { lock.unlock() }
        return present
    }

    func set(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        present = value
    }
}

// MARK: - The sentinel

/// Turns macOS's lock/unlock/sleep/wake notifications into presence
/// transitions, keeps the log on disk, and publishes the flag the ingest path
/// reads.
///
/// Two notification centres, because Apple splits them: the lock and unlock
/// pair are *distributed* notifications (`com.apple.screenIsLocked`, posted
/// system-wide by loginwindow and observable with no entitlement), while
/// sleep, wake and session switching are `NSWorkspace`'s. Nothing here polls
/// and nothing here asks macOS a question.
@MainActor
final class PresenceSentinel {
    static let shared = PresenceSentinel()

    /// Fired when an absence ends, with the window it covered. `AppRuntime`
    /// points this at `CatchUpReporter`.
    var onReturn: ((ClosedRange<Date>) -> Void)?

    /// What the ingest path reads. Shared rather than published: it is asked
    /// once per delivered event, from off the main actor.
    let flag = PresenceFlag()

    private var log: PresenceLog
    private let store: PresenceStore
    /// Kept apart because each token has to go back to the centre that
    /// minted it — `DistributedNotificationCenter` is a `NotificationCenter`
    /// subclass, so mixing them into one list type-checks and then quietly
    /// leaves observers registered.
    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private static let logger = Logger(subsystem: "com.hausfold.trill", category: "presence")

    init(store: PresenceStore = PresenceStore(), now: Date = .now) {
        self.store = store
        // No stored log means this Mac has never run a trill that kept one.
        // Starting *present* is the honest default: the alternative reports
        // every unread row in the retention window as "while you were away"
        // the first time the screen locks.
        log = store.load() ?? PresenceLog(lastPresent: now)
        flag.set(!log.isAway)
    }

    /// Begin listening, and treat the launch itself as a signal — which ends
    /// an absence only if the last run recorded one.
    func start(now: Date = .now) {
        guard distributedObservers.isEmpty, workspaceObservers.isEmpty else { return }

        let distributed = DistributedNotificationCenter.default()
        distributedObservers = [
            observe(distributed, "com.apple.screenIsLocked", as: .locked),
            observe(distributed, "com.apple.screenIsUnlocked", as: .unlocked),
        ]

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            observe(workspace, NSWorkspace.willSleepNotification, as: .slept),
            observe(workspace, NSWorkspace.didWakeNotification, as: .woke),
            observe(workspace, NSWorkspace.sessionDidResignActiveNotification, as: .switchedAway),
            observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, as: .switchedBack),
        ]

        note(.launched, at: now)
    }

    func stop(now: Date = .now) {
        // Quitting is a departure, so a Mac locked at 23:00 that reboots at
        // 03:00 still opens its window at 23:00 — `PresenceLog.note` keeps
        // the earlier stamp.
        note(.quitting, at: now)
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        distributedObservers.removeAll()
        workspaceObservers.removeAll()
    }

    /// The one way in. Exposed so a test can drive a whole night through the
    /// sentinel without a lock screen.
    func note(_ signal: PresenceSignal, at instant: Date = .now) {
        let window = log.note(signal, at: instant)
        store.save(log)
        flag.set(!log.isAway)
        Self.logger.debug("presence: \(signal.rawValue, privacy: .public)")
        guard let window else { return }
        Self.logger.info(
            "back after \(Int(window.upperBound.timeIntervalSince(window.lowerBound)), privacy: .public)s"
        )
        onReturn?(window)
    }

    /// `queue: .main` and `assumeIsolated` rather than a `Task`: the signals
    /// are a sequence — locked *then* unlocked — and hopping each one through
    /// its own task would let two of them land out of order, which is the one
    /// thing the state machine can't survive.
    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name, as signal: PresenceSignal
    ) -> NSObjectProtocol {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.note(signal) }
        }
    }

    private func observe(
        _ center: NotificationCenter, _ name: String, as signal: PresenceSignal
    ) -> NSObjectProtocol {
        observe(center, Notification.Name(name), as: signal)
    }
}
