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
        case .command:
            // User-declared hooks arrive with the rules engine work
            // (PRD milestone 2); until then the action is inert.
            Self.log.info("command hooks not yet enabled (\(event.id, privacy: .public))")
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

    private func openApp(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            Self.log.info("no app for bundle id \(bundleID, privacy: .public)")
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }
}
