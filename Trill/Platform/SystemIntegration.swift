import AppKit
import Security
import ServiceManagement
import UserNotifications
import os.log

/// Every supported hook into Apple's own notification machinery lives here,
/// so the honest boundary is one file wide:
///
///   - login-item registration via `SMAppService` (the supported way to be
///     a resident daemon the user can see and revoke in System Settings);
///   - deep links into System Settings → Notifications, where the user
///     turns Apple's banners off per-app when trill takes over rendering —
///     there is no public API that does that for them;
///   - trill's *own* `UNUserNotificationCenter` registration, used as a
///     diagnostics fallback ("post one through Apple") so side-by-side
///     comparison during onboarding is one click.
///
/// What is deliberately NOT here: any attempt to suppress or intercept other
/// apps' banners programmatically. Suppression is Focus + per-app settings
/// (the Hush lane in the rice); capture is System Mirror's quarantined job.
@MainActor
enum SystemIntegration {
    private static let log = Logger(subsystem: "com.hausfold.trill", category: "system")

    // MARK: - Login item

    static func registerAsLoginItem() {
        do {
            try SMAppService.mainApp.register()
        } catch {
            // Already registered or user-denied: both fine, both visible in
            // System Settings > General > Login Items.
            log.info("login item registration: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func unregisterLoginItem() {
        try? SMAppService.mainApp.unregister()
    }

    static var loginItemStatus: SMAppService.Status {
        SMAppService.mainApp.status
    }

    // MARK: - System Settings deep links

    /// System Settings → Notifications (the whole pane).
    static func openNotificationSettings() {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }

    /// System Settings → Notifications, ideally focused on one app. The
    /// per-app anchor is best-effort — macOS versions differ — the pane
    /// itself always opens.
    static func openNotificationSettings(for bundleID: String) {
        open("x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")
    }

    /// System Settings → Focus, for wiring the Hush-backed replacement mode.
    static func openFocusSettings() {
        open("x-apple.systempreferences:com.apple.Focus-Settings.extension")
    }

    /// System Settings → Privacy & Security → Full Disk Access.
    static func openFullDiskAccessSettings() {
        open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
    }

    // MARK: - Relaunch watchdog (finishing Apple's "Quit & Reopen")

    /// How long after arming the watchdog gives up and stands down. Long
    /// enough to cover a user reading Apple's sheet, short enough that a
    /// forgotten watchdog can't resurrect trill an hour later.
    private static let relaunchWatchdogWindow = 300

    private static var relaunchSentinel: URL? {
        try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        .appendingPathComponent("Trill", isDirectory: true)
        .appendingPathComponent("relaunch-armed")
    }

    /// Arm a detached watcher that re-opens *this exact bundle* if trill dies
    /// while a Full Disk Access grant is in flight.
    ///
    /// This is not an auto-restart — trill picks the grant up live and has no
    /// reason to bounce. It exists for one case: macOS's TCC "Quit & Reopen"
    /// button quits trill and then, for a background-only (`LSUIElement`)
    /// app, routinely never performs the reopen. The user presses a button
    /// promising two things, gets one, and is left with no menu bar item and
    /// no compositor, mid-setup. This finishes the half macOS dropped.
    ///
    /// An external watcher rather than a relaunch spawned from
    /// `applicationWillTerminate`, because we don't get to assume a graceful
    /// exit: if TCC kills the process outright, no delegate method ever runs.
    /// Polling the pid from outside covers both. It reopens by **path**, not
    /// bundle id — LaunchServices can resolve `com.hausfold.trill` to a
    /// stale DerivedData copy the grant was never made against.
    ///
    /// The sentinel file is the disarm channel: `disarmRelaunchWatchdog()`
    /// deletes it, and the watcher re-checks it after trill exits, so a user
    /// who deliberately quits is never resurrected.
    static func armRelaunchWatchdog() {
        guard let sentinel = relaunchSentinel else { return }
        try? FileManager.default.createDirectory(
            at: sentinel.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        guard FileManager.default.createFile(atPath: sentinel.path, contents: nil)
            || FileManager.default.fileExists(atPath: sentinel.path) else { return }

        let script = """
        pid=\(ProcessInfo.processInfo.processIdentifier)
        sentinel=\(shellQuoted(sentinel.path))
        app=\(shellQuoted(Bundle.main.bundleURL.path))
        waited=0
        while kill -0 "$pid" 2>/dev/null; do
            [ "$waited" -ge \(relaunchWatchdogWindow) ] && exit 0
            waited=$((waited + 1))
            sleep 1
        done
        [ -f "$sentinel" ] || exit 0
        rm -f "$sentinel"
        sleep 1
        /usr/bin/open "$app"
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        do {
            try task.run()
        } catch {
            log.error("relaunch watchdog failed to arm: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stand the watchdog down. The watcher process notices on its next
    /// check and exits without reopening anything.
    static func disarmRelaunchWatchdog() {
        guard let sentinel = relaunchSentinel else { return }
        try? FileManager.default.removeItem(at: sentinel)
    }

    private static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Onboarding assistant

    /// Opens the Full Disk Access pane and floats a non-activating helper
    /// panel alongside it. Access is picked up live without quitting or
    /// relaunching the app. `onGrantConfirmed` commits the setting
    /// (through `AppSettings`, so it's flushed to disk) before `onDismiss`
    /// reopens Settings — the panel itself never touches `UserDefaults` directly.
    static func presentFullDiskAccessAssistant(
        onGrantConfirmed: @escaping () -> Void,
        onDismiss: (() -> Void)? = nil
    ) {
        openFullDiskAccessSettings()
        OnboardingAssistantPanelController.shared.present(
            mode: .fullDiskAccess,
            onGrantConfirmed: onGrantConfirmed,
            onDismiss: onDismiss
        )
    }

    /// Walk the user through turning Apple's own banners and sounds off for
    /// the apps an audit flagged — the same floating-panel-beside-System-
    /// Settings shape the Full Disk Access flow uses.
    ///
    /// trill opens the pane and stands next to it; it never writes the
    /// setting. There is no public API to change another app's notification
    /// preferences, and the private store this reads is opened read-only on
    /// purpose (see `NotificationSettingsAudit`) — quietly rewriting a pane
    /// the user believes only they control is not a trade this app makes.
    static func presentNativeBannerAssistant(
        findings: [NativeNotificationSettings],
        onDismiss: (() -> Void)? = nil
    ) {
        guard let first = findings.first else { return }
        openNotificationSettings(for: first.bundleID)
        OnboardingAssistantPanelController.shared.present(
            mode: .nativeBanners(findings: findings),
            onDismiss: onDismiss
        )
    }

    /// Every deep link above lands in this one app.
    /// Also read by the helper panel, which shows its "open the pane" button
    /// only when System Settings *isn't* the app in front.
    static let systemSettingsBundleID = "com.apple.systempreferences"

    private static var raiseTask: Task<Void, Never>?

    private static func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        // The deprecated `open(_:)` never asks for activation, so System
        // Settings came up *behind* whatever the user was looking at. The
        // configuration variant asks; `raiseSystemSettings` insists.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { _, _ in
            Task { @MainActor in raiseSystemSettings() }
        }
        raiseSystemSettings()
    }

    /// Bring System Settings to the front, and keep asking for a beat.
    ///
    /// One activation request is not enough here for two independent
    /// reasons: on a cold launch the process exists before its window does
    /// (activating a windowless app is a no-op), and under a tiling window
    /// manager like AeroSpace the WM re-asserts its own focus right after
    /// the app appears. So poll until it actually reports active, then stop
    /// — never longer, or we'd yank focus back from a user who moved on.
    private static func raiseSystemSettings() {
        raiseTask?.cancel()
        raiseTask = Task { @MainActor in
            for attempt in 0..<12 {
                if attempt > 0 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                if Task.isCancelled { return }
                guard let app = NSRunningApplication.runningApplications(
                    withBundleIdentifier: systemSettingsBundleID
                ).first else { continue }
                if app.isActive && attempt > 0 { return }
                app.unhide()
                app.activate(options: [.activateAllWindows])
            }
        }
    }

    // MARK: - Signing identity (why a grant does or doesn't persist)

    /// The Team ID this build is signed with, or nil when it's ad-hoc /
    /// unsigned.
    ///
    /// This is load-bearing for the Full Disk Access flow, not trivia.
    /// macOS stores a TCC grant against the app's *designated requirement*.
    /// Signed with a Developer ID, that requirement names the team, so the
    /// grant survives every rebuild. Ad-hoc, it names the binary's cdhash —
    /// which changes on every single build — so macOS quietly revokes the
    /// grant (the switch in System Settings flips itself back off) the next
    /// time a differently-hashed Trill.app with this bundle id launches.
    static var teamIdentifier: String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess,
              let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess,
            let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// nil when permissions granted to this build will stick; otherwise the
    /// reason they won't, in one sentence the user can act on.
    static var permissionPersistenceWarning: String? {
        guard teamIdentifier == nil else { return nil }
        return "This is an ad-hoc signed build, so macOS drops its Full Disk Access "
            + "grant every time Trill is rebuilt. Install a Developer ID-signed build "
            + "(scripts/dev-install.sh) to grant it once and keep it."
    }

    // MARK: - Own UN registration (diagnostics)

    static func requestOwnNotificationAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        return (try? await center.requestAuthorization(options: [.alert])) ?? false
    }

    /// Post an event through Apple's pipeline instead of trill's — used by
    /// onboarding/diagnostics to compare the two renderings side by side.
    static func postThroughApple(_ event: NotificationEvent) async {
        let content = UNMutableNotificationContent()
        content.title = event.title
        if let subtitle = event.subtitle { content.subtitle = subtitle }
        if let body = event.body { content.body = body }
        // No .sound, ever.
        let request = UNNotificationRequest(
            identifier: event.id, content: content, trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
