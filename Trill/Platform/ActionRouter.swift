import AppKit
import os.log

/// Delegates actions back to the world: open the source app, open a URL.
/// Capability-gated — the router only ever performs actions the event
/// actually carries, and unknown targets fail quietly into the log, never
/// into a dialog.
@MainActor
final class ActionRouter {
    private static let log = Logger(subsystem: "com.hausfold.trill", category: "actions")

    /// The bundle ids trill is meant to keep macOS quiet for — the sources
    /// the current `rules.json` names. Injected because the router must never
    /// fall back to "every app on this Mac": see `silenceNative` below.
    private let listedApps: () -> [String]

    /// Opens trill's own inbox at a scope. Set by the composition root rather
    /// than injected, because the delegate that owns windows is built after
    /// the router is — and the router, like the socket provider, is meant to
    /// know nothing about windows beyond "someone will show one".
    var openInbox: ((InboxScope) -> Void)?

    init(listedApps: @escaping () -> [String] = { [] }) {
        self.listedApps = listedApps
    }

    /// Click on the banner body, or on one row of an expanded fold: first
    /// declared action wins, falling back to activating the source app when
    /// the event's source looks like a bundle id.
    ///
    /// `NotificationEvent.hasDefaultAction` is exactly the set of events this
    /// does something for, and the banner asks it before drawing a row as
    /// pressable — keep the two in step or trill starts drawing dead buttons.
    func performDefault(for event: NotificationEvent) {
        guard event.hasDefaultAction else { return }
        if let action = event.actions.first {
            perform(action, for: event)
        } else {
            openApp(bundleID: event.source)
        }
    }

    func perform(_ action: NotificationEvent.Action, for event: NotificationEvent) {
        switch action.kind {
        case .openApp:
            openApp(bundleID: action.target ?? event.source)
        case .openURL:
            // Same predicate `hasDefaultAction` draws from, so a row can never
            // be drawn pressable for a URL this would then refuse.
            guard NotificationEvent.Action.opensAsURL(action.target),
                  let target = action.target,
                  let url = URL(string: target)
            else {
                Self.log.info("refused non-web/file URL action for \(event.id, privacy: .public)")
                return
            }
            NSWorkspace.shared.open(url)
        case .focusLane:
            focusLane(action.target, for: event)
        case .openInbox:
            // The click *is* the summons, same as `trill inbox` — so opening
            // a window here doesn't break the never-steal-focus rule.
            guard let scope = InboxScope(actionTarget: action.target) else {
                Self.log.info("refused a malformed inbox scope for \(event.id, privacy: .public)")
                return
            }
            openInbox?(scope)
        case .command:
            // User-declared hooks arrive with the rules engine work
            // (PRD milestone 2); until then the action is inert.
            Self.log.info("command hooks not yet enabled (\(event.id, privacy: .public))")
        case .unsupported:
            // A newer sender named a kind this build doesn't have. The event
            // still banners — only the action is inert — so this is a version
            // note, not a fault.
            Self.log.info("unknown action kind for \(event.id, privacy: .public)")
        case .silenceNative:
            // The target names the apps this banner was about — one id, or the
            // whole worklist the collapsed summary counted. A target-less
            // event (hand-authored, or from an older trill) falls back to the
            // apps `rules.json` lists, never to every app on the Mac: trill
            // asks people to silence what it's been told to redraw, not to
            // switch macOS's notifications off wholesale.
            let scope = NotificationSettingsAudit.scope(forActionTarget: action.target)
                ?? .only(listedApps())
            var named: [String] = []
            if case .only(let ids) = scope { named = ids }

            // A click must always *do* something. The banner is still on
            // screen; a click that logs and opens no window reads as trill
            // being broken, whatever the reason was.
            guard let store = NotificationSettingsAudit.readAll() else {
                // Can't read the store (no Full Disk Access). The walkthrough
                // still works — it just can't tick anything off by itself —
                // so open it on the apps the banner named.
                Self.log.info("silence action for \(event.id, privacy: .public): settings unreadable, walking blind")
                if named.isEmpty {
                    SystemIntegration.openNotificationSettings()
                } else {
                    SystemIntegration.presentNativeBannerAssistant(
                        findings: named.map(NativeNotificationSettings.unknown(bundleID:))
                    )
                }
                return
            }
            // Re-running the audit rather than trusting the event's payload
            // keeps the window honest about *now* — the user may have fixed
            // one of them while the banner sat on screen.
            let findings = NotificationSettingsAudit.findings(scope: scope, settings: store)
            guard findings.isEmpty else {
                SystemIntegration.presentNativeBannerAssistant(findings: findings)
                return
            }
            // Fixed while the banner sat there. Open on those same apps
            // anyway: every one is quiet now, so the panel goes straight to
            // its all-clear card and closes itself — which is the answer to
            // "what happened to the thing I clicked".
            Self.log.info("silence action for \(event.id, privacy: .public): nothing left to silence")
            let quiet = named.compactMap { store[$0] }
            if quiet.isEmpty {
                SystemIntegration.openNotificationSettings()
            } else {
                SystemIntegration.presentNativeBannerAssistant(findings: quiet)
            }
        }
    }

    /// Bring a holt lane's window to the front.
    ///
    /// trill knows nothing about terminals, tilers or window ids, and must
    /// not learn: which window is a lane is the desktop layer's join, and it
    /// already owns a careful answer. So this runs exactly one binary with
    /// exactly one validated argument and no shell in between — the mirror of
    /// how holt reaches `trill send` — and `holt focus` delegates onward from
    /// there. That narrowness is why this is a named capability rather than
    /// the general command hook the PRD defers: the router can still say, in
    /// one line, everything a banner click is able to run.
    ///
    /// It moves focus to the lane's terminal, never to trill — the "never
    /// steal focus" rule is about windows the user didn't summon, and a click
    /// on the banner is the summons.
    private func focusLane(_ target: String?, for event: NotificationEvent) {
        guard NotificationEvent.Action.focusesLane(target), let lane = target else {
            Self.log.info("refused a malformed lane target for \(event.id, privacy: .public)")
            return
        }
        guard let binary = Self.holtBinary() else {
            Self.log.info("no holt on this Mac — can't focus a lane (\(event.id, privacy: .public))")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["focus", lane]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            // Launched and forgotten: the raise is holt's to finish, and
            // waiting on it would block the main actor on another process.
            try process.run()
        } catch {
            Self.log.info("holt focus wouldn't launch for \(event.id, privacy: .public)")
        }
    }

    /// Where `holt` is, from inside a GUI app. A bundle inherits
    /// `/usr/bin:/bin:/usr/sbin:/sbin` and nothing else, so a PATH search
    /// alone finds nothing on a nix machine — the same reason holt's own
    /// `trillBinary()` walks known locations to find Trill.app. `TRILL_HOLT`
    /// is authoritative when set, including set to something missing, which
    /// is how a machine (or a test) says "no lane focus here".
    private static func holtBinary() -> String? {
        let fm = FileManager.default
        func usable(_ path: String) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDir)
                && !isDir.boolValue && fm.isExecutableFile(atPath: path)
        }
        if let override = ProcessInfo.processInfo.environment["TRILL_HOLT"], !override.isEmpty {
            return usable(override) ? override : nil
        }
        let home = fm.homeDirectoryForCurrentUser.path
        let candidates = [
            "/run/current-system/sw/bin/holt",
            "/etc/profiles/per-user/\(NSUserName())/bin/holt",
            "\(home)/.nix-profile/bin/holt",
            "/opt/homebrew/bin/holt",
            "/usr/local/bin/holt",
        ]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") where !dir.isEmpty {
                let candidate = "\(dir)/holt"
                if usable(candidate) { return candidate }
            }
        }
        return candidates.first(where: usable)
    }

    private func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Self.log.info("no app for bundle id \(bundleID, privacy: .public)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
