import AppKit
import Foundation
import os.log

/// What macOS itself will do with one app's notifications.
///
/// This is the *other* app's settings, not trill's: the row you'd see under
/// System Settings → Notifications → <app>. trill reads it to answer one
/// question — "if I draw this event, will Apple draw it too?" — because a
/// mirrored notification that macOS also banners is a duplicate, and one it
/// also sounds is a duplicate that beeps.
struct NativeNotificationSettings: Sendable, Equatable, Codable {
    /// Whether — and for how long — macOS draws this app on screen.
    ///
    /// macOS 26 (Tahoe) reshaped this pane: the old three-way "Alert style"
    /// (None / Banners / Alerts) is now a **Desktop** checkbox plus a
    /// two-way Temporary/Persistent radio that only matters while Desktop is
    /// ticked. The underlying bits didn't move — bit 3 is Temporary, bit 4 is
    /// Persistent, and clearing Desktop clears both — so `off` is still the
    /// state trill wants an app it mirrors to be in. Only the words changed,
    /// and the words are what the helper has to say out loud.
    enum DesktopAlert: String, Sendable, Codable {
        /// "Desktop" unchecked: it still reaches Notification Center, but
        /// nothing is drawn over your work.
        case off
        /// Desktop ✓, Alert Style = Temporary (what used to be Banners).
        case temporary
        /// Desktop ✓, Alert Style = Persistent (what used to be Alerts).
        case persistent
    }

    var bundleID: String
    var desktopAlert: DesktopAlert
    var playsSound: Bool
    var badgesIcon: Bool
    /// The master "Allow notifications" switch. **Load-bearing**: macOS keeps
    /// the style and sound bits at their old values when this goes off, so an
    /// app the user silenced years ago still reads as "banners + sound" until
    /// you check this first.
    var allowsNotifications: Bool
    /// False for the rows System Settings doesn't list under Application
    /// Notifications at all — the background agents, and a few Apple apps.
    /// There's nothing for a user to click, so pointing them at it is a
    /// dead end.
    var hasSettingsRow: Bool

    /// Is the **Desktop** checkbox ticked? That's the one that decides
    /// whether macOS draws over your work, and so the one trill cares about.
    var showsOnDesktop: Bool { desktopAlert != .off }

    /// The whole point of the audit. True when macOS will still draw or sound
    /// this app's notifications itself.
    var isNoisy: Bool {
        allowsNotifications && (showsOnDesktop || playsSound)
    }

    /// The summary line System Settings puts under the app's name in
    /// Application Notifications ("Badges, Sounds, and Desktop"). Rebuilt
    /// from the same bits so the helper can show the user the exact row to
    /// look for — the per-app deep link lands on the top of the pane, not on
    /// the app, so scanning for the row is the step that actually happens.
    var settingsSubtitle: String {
        guard allowsNotifications else { return "Off" }
        var parts: [String] = []
        if badgesIcon { parts.append("Badges") }
        if playsSound { parts.append("Sounds") }
        if showsOnDesktop { parts.append("Desktop") }
        switch parts.count {
        case 0: return "Off"
        case 1: return parts[0]
        case 2: return "\(parts[0]) and \(parts[1])"
        default: return parts.dropLast().joined(separator: ", ") + ", and " + parts[parts.count - 1]
        }
    }

    /// A stand-in for an app whose real settings trill couldn't read (no Full
    /// Disk Access). Both controls read as on, which is the safe assumption:
    /// the walkthrough then names both, and naming a switch that's already off
    /// costs a glance — while staying silent about one that's on costs the
    /// duplicate banner this whole flow exists to stop.
    static func unknown(bundleID: String) -> NativeNotificationSettings {
        NativeNotificationSettings(
            bundleID: bundleID,
            desktopAlert: .temporary,
            playsSound: true,
            badgesIcon: false,
            allowsNotifications: true,
            hasSettingsRow: true
        )
    }

    /// One line naming only what's still wrong, in the words the current
    /// System Settings pane uses — "Desktop" and "sound" are the two labels
    /// the user is about to go looking for.
    var complaint: String? {
        guard isNoisy else { return nil }
        var parts: [String] = []
        if showsOnDesktop { parts.append("on the Desktop") }
        if playsSound { parts.append("with a sound") }
        return "macOS still shows this " + parts.joined(separator: ", ")
    }
}

/// Reads Apple's per-app notification preferences and reports which apps
/// would double up with trill.
///
/// **Read-only, and undocumented.** `com.apple.ncprefs` is a private
/// preference domain: Apple documents no reader, no writer, and no bit
/// layout. So this file follows the same quarantine rule System Mirror does —
/// it decodes defensively, never writes (silencing an app is always the
/// user's click in System Settings, never ours), and a layout it can't make
/// sense of degrades to "nothing to report" rather than to a wrong answer.
///
/// The flag bits below are reverse-engineered, and none is relied on until
/// it's been corroborated:
///
///   - **style and sound** — against the long-standing community tool
///     (`drewdiver/ncprefs.py`, a descendant of Jacob Salmela's NCUtil), and
///     empirically against a 92-app preference file where `(flags >> 3) &
///     0b11` took only the values 0, 1 and 2 across every app: a two-bit
///     field, not three unrelated booleans.
///   - **allow-notifications** — against 19 apps whose real state was read
///     straight off the System Settings pane. This one was found the
///     expensive way: the first cut shipped without it and cheerfully told
///     the user to silence Calendar, ghostty and Chrome, all of which they'd
///     switched off years earlier. macOS leaves the style and sound bits
///     frozen at their last values when the master switch goes off, so
///     *every* audit that skips this bit over-reports.
///
/// Bits with plausible community mappings that the data does **not**
/// corroborate (lock screen, time-sensitive, critical) are not read at all.
/// One of them is instructive: the community's `TIME_SENSITIVE_APPS` list
/// matches bit 29's set here almost exactly, which is how bit 29 was ruled
/// *out* as the allow bit rather than adopted as it.
enum NotificationSettingsAudit {
    private static let log = Logger(subsystem: "com.hausfold.trill", category: "audit")

    /// trill reads exactly the three bits it needs, and deliberately ignores
    /// the rest. Several other bits in this field (lock-screen visibility,
    /// time-sensitive, critical) have plausible community mappings that this
    /// machine's data does *not* corroborate, so acting on them would be
    /// guessing. Alert style and sound are the two that matter and the two
    /// that are solid.
    enum Flag {
        /// Bits 3–5 hold the on-screen alert. Neither set = the **Desktop**
        /// checkbox is clear. Confirmed against a Tahoe pane showing
        /// Desktop ✓ / Persistent for an app whose bit 4 is set.
        static let temporary: UInt64 = 1 << 3
        static let persistent: UInt64 = 1 << 4
        static let playSound: UInt64 = 1 << 2
        static let badgeAppIcon: UInt64 = 1 << 1
        /// "Allow notifications". Pinned against 19 apps whose real state was
        /// read out of System Settings: 0 for all 15 showing **Off**, 1 for
        /// three of the four showing "Badges, Sounds, and Desktop".
        ///
        /// The one miss is an app with `auth == 0` — never prompted, so macOS
        /// has no decision recorded and shows it enabled-looking anyway.
        /// Treating `auth == 0` as allowed was tried and is *worse* (it breaks
        /// two other apps), and no second bit separates the case without
        /// obvious overfitting, so this stays a single bit. It errs toward
        /// under-reporting — trill stays quiet about an app it might have
        /// nagged over — which is the right direction for a nag.
        static let allowNotifications: UInt64 = 1 << 25
        /// Set on rows System Settings does not list under Application
        /// Notifications. Every app carrying it here is an Apple background
        /// agent (tccd, PlatformSSO, the timezone notifier) plus Clock and
        /// Shortcuts — and Clock's absence from the list is confirmed
        /// directly. Used only to *hide* rows, so being wrong costs an
        /// omission, never a dead end.
        static let noSettingsRow: UInt64 = 1 << 7
    }

    /// **Where the switches actually live on macOS 26.**
    ///
    /// `com.apple.ncprefs` — the domain every write-up on the internet names,
    /// and the one trill shipped against — is a **stale mirror** on Tahoe. It
    /// still holds an `apps` array of plausible `flags`, so nothing about
    /// reading it looks wrong; it is simply not the file System Settings
    /// writes. Measured on this machine: the whole 92-app store was
    /// byte-identical to a copy 17 days old, across a change made in the pane
    /// and 45 minutes of watching, while the group-container store below
    /// picked the same change up within seconds. That is what made the helper
    /// panel look broken — it polled a file that no longer moves.
    ///
    /// The group container is TCC-protected, so this read needs **Full Disk
    /// Access**, the same grant System Mirror asks for. That is why every
    /// reader here is optional: a process without the grant must answer
    /// "can't tell", never "all quiet" (see `readAll`).
    private static var settingsStore: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Group Containers/group.com.apple.usernoted/Library/Preferences/"
                    + "group.com.apple.usernoted.plist"
            )
    }

    // MARK: - Pure decoding (tested)

    /// Decode one app's flags word. Pure — the tests drive this directly.
    static func decode(bundleID: String, flags: UInt64) -> NativeNotificationSettings {
        let alert: NativeNotificationSettings.DesktopAlert
        if flags & Flag.temporary != 0 {
            alert = .temporary
        } else if flags & Flag.persistent != 0 {
            alert = .persistent
        } else {
            alert = .off
        }
        return NativeNotificationSettings(
            bundleID: bundleID,
            desktopAlert: alert,
            playsSound: flags & Flag.playSound != 0,
            badgesIcon: flags & Flag.badgeAppIcon != 0,
            allowsNotifications: flags & Flag.allowNotifications != 0,
            hasSettingsRow: flags & Flag.noSettingsRow == 0
        )
    }

    /// Entries macOS manages on its own behalf — software updates, keychain
    /// prompts, the account-security alerts. They're prefixed in the store,
    /// the user can't meaningfully retune them, and trill never mirrors them,
    /// so they'd be pure noise in an audit aimed at "apps you use".
    static func isSystemManaged(bundleID: String) -> Bool {
        bundleID.hasPrefix("_SYSTEM_CENTER_:")
    }

    /// Decode a whole `apps` array as read from the preference domain.
    /// Pure, so the tests can feed it a fixture instead of a real Mac.
    static func decode(appsArray: [[String: Any]]) -> [NativeNotificationSettings] {
        appsArray.compactMap { entry in
            guard let bundleID = entry["bundle-id"] as? String,
                  !isSystemManaged(bundleID: bundleID),
                  // `flags` is a plist integer; NSNumber covers every width
                  // it's been seen as, and some entries have grown past 32
                  // bits on recent macOS.
                  let flags = (entry["flags"] as? NSNumber)?.uint64Value
            else { return nil }
            return decode(bundleID: bundleID, flags: flags)
        }
    }

    // MARK: - Reading the live store

    /// Every app macOS has notification preferences for, keyed by bundle id —
    /// or **nil when the store can't be read**, which on a Mac that hasn't
    /// granted Full Disk Access is the normal answer.
    ///
    /// Optional on purpose. An audit has three verdicts, not two: noisy,
    /// quiet, and *can't tell* — and "can't tell" rendered as "all clear" is
    /// the one failure mode that has trill telling someone their
    /// notifications are fine while macOS doubles every banner.
    static func readAll() -> [String: NativeNotificationSettings]? {
        guard let apps = readAppsArray() else {
            log.info("notification settings unreadable — audit answering 'unknown'")
            return nil
        }
        let decoded = decode(appsArray: apps)
        return Dictionary(decoded.map { ($0.bundleID, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Why the store couldn't be read, in words a user can act on — nil when
    /// it reads fine.
    static func unreadableReason() -> String? {
        readAppsArray() == nil
            ? "trill needs Full Disk Access to read macOS's notification settings."
            : nil
    }

    /// Read straight off the file, fresh every time.
    ///
    /// Not through CFPreferences: the group container isn't served under its
    /// plain domain name (`defaults export group.com.apple.usernoted` comes
    /// back with nothing), and there is no entitlement trill could hold for
    /// one of Apple's own app groups. A fresh read per poll is the point
    /// regardless — this file moves within seconds of a switch being flipped,
    /// which is the entire question the helper panel asks.
    private static func readAppsArray() -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: settingsStore),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let apps = plist["apps"] as? [[String: Any]]
        else { return nil }
        return apps
    }

    // MARK: - The audit

    /// The apps trill is expected to keep quiet, in the order they should be
    /// dealt with.
    ///
    /// `scope` is what "a listed app" means in practice — see
    /// `NotificationSettingsAudit.Scope`.
    enum Scope: Sendable, Equatable {
        /// Exactly these bundle ids (a `trill doctor com.foo.bar` invocation,
        /// or the sources named in `rules.json`).
        case only([String])
        /// Every non-system app macOS holds preferences for. **Only ever
        /// reached by asking for it** — `trill doctor --all`, and nothing
        /// else.
        ///
        /// It is deliberately *not* the default, not even with System Mirror
        /// on. trill's offer is "the apps you told me about stay quiet", not
        /// "turn macOS's notifications off"; a helper that walks someone
        /// through silencing sixty apps they never listed is asking them to
        /// dismantle their Mac's notifications on trill's say-so. Anything
        /// that picks a scope on the user's behalf picks `.only` — see
        /// `SocketProvider` (the daemon's own listed apps), `SettingsView`,
        /// and `ActionRouter`.
        case everything
    }

    /// The bundle ids a rule set names — trill's "listed apps", and the
    /// default scope for a bare `trill doctor`.
    ///
    /// A rule's `source` is either a short slug (`deploy`, `ci`) or a bundle
    /// id for a mirrored system app; only the latter has notification
    /// settings to audit, and a dot is what tells them apart.
    static func listedBundleIDs(in ruleSet: RuleSet) -> [String] {
        var seen: Set<String> = []
        return ruleSet.rules
            .compactMap(\.match.source)
            .filter { $0.contains(".") }
            .filter { seen.insert($0).inserted }
    }

    /// trill's own row is in this store too, and telling the user to silence
    /// trill's banners in order to stop duplicate trill banners is a loop.
    private static var ownBundleID: String {
        // A Debug build is `…trill.debug` (see `AppPaths`), and the row it
        // must skip is still the installed app's — otherwise a debug `--all`
        // audit cheerfully tells you to go silence trill.
        (Bundle.main.bundleIdentifier ?? "com.hausfold.trill")
            .replacingOccurrences(of: ".debug", with: "")
    }

    /// Does something on this Mac actually claim this bundle id? Injectable
    /// so `findings` stays testable without a real LaunchServices database.
    static let bundleIsInstalled: @Sendable (String) -> Bool = { bundleID in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// The noisy apps in scope, worst first (alerts before banners, sound
    /// breaking ties), then alphabetical so the order is stable between runs.
    /// The live audit, or **nil when the store can't be read** — the caller
    /// must render that as "can't tell", never as "nothing to do".
    static func liveFindings(
        scope: Scope,
        isInstalled: (String) -> Bool = bundleIsInstalled
    ) -> [NativeNotificationSettings]? {
        guard let all = readAll() else { return nil }
        return findings(scope: scope, settings: all, isInstalled: isInstalled)
    }

    static func findings(
        scope: Scope,
        settings: [String: NativeNotificationSettings],
        isInstalled: (String) -> Bool = bundleIsInstalled
    ) -> [NativeNotificationSettings] {
        let all = settings
        let candidates: [NativeNotificationSettings]
        switch scope {
        case .only(let ids):
            // Named explicitly, so it's reported even if nothing on this Mac
            // claims the id — an app you uninstalled still has a row, and
            // silently dropping it would look like the audit was broken.
            candidates = ids.compactMap { all[$0] }
        case .everything:
            // A stock Mac holds preferences for dozens of things that are not
            // apps you can act on: invisible background agents, and rows
            // System Settings simply doesn't list. Both are dead ends for a
            // worklist, which is the one thing `--all` is for.
            candidates = all.values.filter { $0.hasSettingsRow && isInstalled($0.bundleID) }
        }
        return candidates
            .filter { $0.isNoisy && $0.bundleID != ownBundleID }
            .sorted { lhs, rhs in
                let rank = { (s: NativeNotificationSettings) -> Int in
                    (s.desktopAlert == .persistent ? 2 : s.desktopAlert == .temporary ? 1 : 0)
                        + (s.playsSound ? 1 : 0)
                }
                if rank(lhs) != rank(rhs) { return rank(lhs) > rank(rhs) }
                return lhs.bundleID < rhs.bundleID
            }
    }

    // MARK: - Reporting as banners

    /// How many individual apps are worth one banner each before the report
    /// collapses into a single summary. Past this, a banner per app *is* the
    /// notification storm trill exists to prevent.
    static let individualBannerLimit = 3

    /// A `silenceNative` action's target: one bundle id, or several joined by
    /// commas when one banner stands for a whole worklist. Bundle ids can't
    /// contain a comma, so the join is unambiguous.
    ///
    /// The list is carried explicitly rather than left for the click to
    /// re-derive, because the audit that produced the banner had a *scope* —
    /// usually the listed apps — and re-auditing from scratch on click would
    /// silently widen it to the whole Mac.
    static func actionTarget(for findings: [NativeNotificationSettings]) -> String {
        findings.map(\.bundleID).joined(separator: ",")
    }

    /// The scope an action target names, or nil when it names nothing (an
    /// event authored by hand, or one from an older trill). Callers decide
    /// what nil means; none of them may answer `.everything`.
    static func scope(forActionTarget target: String?) -> Scope? {
        guard let target else { return nil }
        let ids = target
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return ids.isEmpty ? nil : .only(ids)
    }

    /// The banner(s) `trill doctor --notify` puts on screen. Pure, so the
    /// wording and the collapse threshold are testable without a display.
    ///
    /// One action, always — clicking the banner opens the helper. There is no
    /// "fix it for me" here and there can't be: Apple exposes no API to write
    /// another app's notification settings, so the honest offer is to open the
    /// right pane and show the user exactly which two boxes to clear.
    static func bannerEvents(for findings: [NativeNotificationSettings]) -> [NotificationEvent] {
        guard !findings.isEmpty else { return [] }

        func action(target: String) -> NotificationEvent.Action {
            .init(id: "silence", label: "Silence Native Banners", kind: .silenceNative, target: target)
        }

        // Too many to list: one banner for the lot, and the helper steps
        // through them. Better than burying the screen in its own duplicates.
        guard findings.count <= individualBannerLimit else {
            return [NotificationEvent(
                source: "trill",
                title: "\(findings.count) apps still show native banners",
                body: "macOS is drawing these itself, so you'll see everything twice.",
                symbol: "bell.badge.slash",
                thread: "trill-doctor",
                // The exact apps this banner counted — not "re-audit and see".
                actions: [action(target: actionTarget(for: findings))]
            )]
        }

        return findings.map { finding in
            NotificationEvent(
                source: "trill",
                title: "\(displayName(for: finding.bundleID)) still shows native banners",
                body: finding.complaint,
                symbol: "bell.badge.slash",
                thread: "trill-doctor",
                actions: [action(target: actionTarget(for: [finding]))]
            )
        }
    }

    // MARK: - Naming

    /// The app's icon, for the "find this row" replica. nil when nothing on
    /// this Mac claims the id.
    static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    /// A human name for a bundle id, or the id back when nothing on this Mac
    /// claims it (an app that was uninstalled still has a preferences row).
    static func displayName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }
}
