import Foundation
import os.log

// MARK: - The verdict

/// Whether macOS is in a Focus right now, and which one — **read, never
/// written**.
///
/// trill has no business turning a Focus on or off: that dial is the desktop's
/// (haus's "Hush" lane owns it) and the user's, and a compositor that flipped
/// it would be changing the whole Mac to change its own banners. What trill
/// does is *notice*, and route accordingly — see `RuleSet.FocusPolicy`.
///
/// There are **three** verdicts and not two, for the same reason
/// `NotificationSettingsAudit` has three: the store is a file, and a file can
/// be unreadable. `unknown` fails **open** — trill behaves exactly as if no
/// Focus were on — because a compositor that silences your chats on the
/// strength of a file it couldn't parse is worse than one that misses a Focus.
///
/// Named `SystemFocus` and not `FocusState` because SwiftUI already owns that
/// spelling: a module-level `FocusState` shadows the property wrapper, and
/// `@FocusState` in the inbox's search field stops compiling with an error
/// that says nothing about this file.
enum SystemFocus: Equatable, Sendable {
    /// Nothing is asserted. The everyday case.
    case off
    /// A Focus is on. `mode` is what to call it out loud.
    case on(FocusMode)
    /// trill couldn't tell — the store moved, changed shape, or isn't
    /// readable. Treated as `off` everywhere a decision is made; said out
    /// loud in Settings so a user isn't left guessing why nothing changed.
    case unknown(String)

    var mode: FocusMode? {
        if case .on(let mode) = self { return mode }
        return nil
    }

    /// The one question `PolicyEngine` asks. `unknown` is deliberately false.
    var isOn: Bool { mode != nil }

    /// What Settings says out loud, or nil when there is nothing to say.
    var reason: String? {
        switch self {
        case .off: nil
        case .on(let mode): "\(mode.label) is on."
        case .unknown(let why): "trill can’t tell whether a Focus is on — \(why)"
        }
    }
}

/// The Focus itself, as macOS names it.
struct FocusMode: Equatable, Sendable {
    /// `com.apple.focus.work`, `com.apple.donotdisturb.mode.default`, …
    var identifier: String
    /// The name shown in the Focus pane, when `ModeConfigurations.json` was
    /// readable. Optional because the *state* file is the one that matters:
    /// a Focus trill can see but can't name is still a Focus.
    var name: String?

    /// What to print. The fallbacks cover the two identifiers macOS ships
    /// that no user ever renamed; anything else keeps its last component
    /// rather than inventing a title for a mode somebody built themselves.
    var label: String {
        if let name, !name.isEmpty { return name }
        switch identifier {
        case "com.apple.donotdisturb.mode.default": return "Do Not Disturb"
        case "com.apple.sleep.sleep-mode": return "Sleep"
        default:
            let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
            return tail.replacingOccurrences(of: "-", with: " ").capitalized
        }
    }
}

// MARK: - Pure decoding (tested)

/// Where macOS keeps the Focus state, and how to read it without guessing.
///
/// **`~/Library/DoNotDisturb/DB/Assertions.json` is the live file.** A Focus
/// that is on has an entry in `storeAssertionRecords`; turning it off does not
/// delete the entry so much as move it into `storeInvalidationRecords`, which
/// is why the two have to be told apart rather than counted together — the
/// invalidation list is a history of every Focus you have ever ended, and a
/// reader that walked it would report a Focus from March.
///
/// The name lives in a second file, `ModeConfigurations.json`, keyed by the
/// same mode identifier. It is only ever used for a label; nothing decides
/// anything on it.
///
/// Both are read-only, and both are plain JSON in the user's own home —
/// **not** a TCC-protected group container like the notification-settings
/// store. If that ever changes, the read fails and this reports `unknown`,
/// which is the whole reason that case exists.
///
/// Measured on macOS 26.6, 2026-08-25, in both states: with nothing asserted
/// the `storeAssertionRecords` key is *absent* rather than empty (hence the
/// optional walk below, and hence "no records" being a fact and not a
/// failure), and with Do Not Disturb on it carries one record identifying
/// `com.apple.donotdisturb.mode.default`, within a second of the toggle.
enum FocusStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    static var assertionsFile: URL {
        directory.appendingPathComponent("Assertions.json")
    }

    static var modeConfigurationsFile: URL {
        directory.appendingPathComponent("ModeConfigurations.json")
    }

    /// The whole decision, as a pure function of two file bodies. Fed a
    /// fixture by the tests; fed real bytes by `FocusReader` and nothing else.
    static func evaluate(assertions: Data, modeConfigurations: Data?) -> SystemFocus {
        guard let root = try? JSONSerialization.jsonObject(with: assertions) as? [String: Any],
              let data = root["data"] as? [[String: Any]]
        else {
            // Schema drift, not absence: the file was there and did not look
            // like itself. Same posture System Mirror takes on a failed probe
            // — off, with a reason, never a guess.
            return .unknown("macOS’s Focus store isn’t in the shape trill knows")
        }

        let identifiers = data
            .compactMap { $0["storeAssertionRecords"] as? [[String: Any]] }
            .flatMap { $0 }
            .compactMap { record -> String? in
                guard let details = record["assertionDetails"] as? [String: Any] else { return nil }
                return details["assertionDetailsModeIdentifier"] as? String
            }

        // No records is the everyday reading, and it is a *fact*, not a
        // failure: the key is simply absent while nothing is asserted.
        guard let identifier = identifiers.first else { return .off }

        let names = modeConfigurations.flatMap(modeNames(in:)) ?? [:]
        return .on(FocusMode(identifier: identifier, name: names[identifier]))
    }

    /// Mode identifier → the name the user sees in the Focus pane. Best
    /// effort by design: a missing or unreadable file costs a label, never a
    /// verdict.
    static func modeNames(in data: Data) -> [String: String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["data"] as? [[String: Any]]
        else { return [:] }

        var names: [String: String] = [:]
        for entry in entries {
            guard let configurations = entry["modeConfigurations"] as? [String: Any] else { continue }
            for (identifier, configuration) in configurations {
                guard let configuration = configuration as? [String: Any],
                      let mode = configuration["mode"] as? [String: Any],
                      let name = mode["name"] as? String, !name.isEmpty
                else { continue }
                names[identifier] = name
            }
        }
        return names
    }
}

// MARK: - The reading, live

/// Reads `SystemFocus` off the live system, from any thread, with a one-second
/// memo.
///
/// **No timer and no watcher**, unlike `ScreenWatch` — and that is the point.
/// The reading is only ever needed at the instant a decision is made (one per
/// delivered event, off the main actor, in `EventRepository.ingest`), so
/// reading it *then* is both cheaper than a poll and impossible to miss a
/// change with. The memo exists so a burst of fifty events costs one read of a
/// 3 KB file rather than fifty, and it is a second because that is far below
/// the time it takes anyone to notice a banner.
///
/// The `enabled` gate lives here rather than in `PolicyEngine` so the engine
/// stays a pure function of (event, rules, clock, focus): with the switch off
/// this hands it `.off`, and every decision is bit-for-bit what it was before
/// this file existed. `reading()` is the ungated truth, which is what Settings
/// shows — the switch has to be understandable before it is flipped.
final class FocusReader: @unchecked Sendable {
    private let lock = NSLock()
    private let enabled: @Sendable () -> Bool
    private var cached: (state: SystemFocus, at: Date)?

    /// How long one reading stands in for the next.
    static let memo: TimeInterval = 1

    private static let log = Logger(subsystem: "com.hausfold.trill", category: "focus")

    init(enabled: @escaping @Sendable () -> Bool = {
        ConfigFileStore.shared.current().focusAware
    }) {
        self.enabled = enabled
    }

    /// What the store says, whatever the switch says.
    func reading(now: Date = .now) -> SystemFocus {
        lock.lock()
        defer { lock.unlock() }
        if let cached, now.timeIntervalSince(cached.at) < Self.memo, now >= cached.at {
            return cached.state
        }
        let state = Self.readSystem()
        if cached?.state != state {
            Self.log.info("focus: \(Self.describe(state), privacy: .public)")
        }
        cached = (state, now)
        return state
    }

    /// What `PolicyEngine` gets: the reading, or `.off` while the user has
    /// asked trill not to care.
    func effective(now: Date = .now) -> SystemFocus {
        guard enabled() else { return .off }
        return reading(now: now)
    }

    /// Throw the memo away — for a Settings pane that wants the state *now*,
    /// and for the tests.
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        cached = nil
    }

    // MARK: - The Apple side

    /// One reading of the two files. The only part of this type that touches
    /// the disk, and the only part not exercised by a test.
    private static func readSystem() -> SystemFocus {
        guard let assertions = try? Data(contentsOf: FocusStore.assertionsFile) else {
            // A missing file inside a directory that exists is macOS simply
            // never having written one — no Focus has ever been asserted on
            // this Mac. A missing *directory* is a different machine than the
            // one this code was written against, and that is a "can't tell".
            var isDirectory: ObjCBool = false
            let hasDirectory = FileManager.default.fileExists(
                atPath: FocusStore.directory.path, isDirectory: &isDirectory
            )
            return hasDirectory && isDirectory.boolValue
                ? .off
                : .unknown("macOS’s Focus store isn’t where trill expects it")
        }
        return FocusStore.evaluate(
            assertions: assertions,
            modeConfigurations: try? Data(contentsOf: FocusStore.modeConfigurationsFile)
        )
    }

    /// Log-safe: an identifier and nothing else. Focus modes are named by the
    /// people who make them ("Therapy", "Job hunt"), so the *label* stays out
    /// of the log the way notification content does.
    private static func describe(_ state: SystemFocus) -> String {
        switch state {
        case .off: "off"
        case .on(let mode): "on (\(mode.identifier))"
        case .unknown: "unreadable"
        }
    }
}

// MARK: - The sentinel

/// The live readout Settings shows, and the shared reader everything else
/// uses.
///
/// Thin on purpose: the reader is the mechanism, this is only a `@Published`
/// mirror for a window that happens to be open. It polls while — and only
/// while — that window is showing, exactly like `ScreenWatchSentinel`, because
/// a readout that updates once when the pane opens is furniture.
@MainActor
final class FocusSentinel: ObservableObject {
    static let shared = FocusSentinel()

    /// What the store says, whatever the switch says.
    @Published private(set) var state: SystemFocus = .off

    let reader: FocusReader
    private var timer: Timer?

    init(reader: FocusReader = FocusReader()) {
        self.reader = reader
    }

    func refresh() {
        reader.invalidate()
        let state = reader.reading()
        guard state != self.state else { return }
        self.state = state
    }

    func setPolling(_ on: Bool) {
        guard on != (timer != nil) else { return }
        guard on else {
            timer?.invalidate()
            timer = nil
            return
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 0.5
        self.timer = timer
    }
}
