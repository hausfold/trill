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

    /// System Settings → Privacy & Security → Calendars, where a refused or
    /// write-only calendar grant is fixed. macOS only presents its own sheet
    /// once, so after a "Don't Allow" this pane is the only road back.
    static func openCalendarPrivacySettings() {
        open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Calendars")
    }

    /// System Settings → Privacy & Security → Full Disk Access.
    static func openFullDiskAccessSettings() {
        open("x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")
    }

    // MARK: - `trill` on PATH

    /// What `trill` resolves to for a shell, and how it got there.
    enum CLILinkState: Equatable, Sendable {
        /// Switched off in config.json — trill placed nothing.
        case off
        /// Another install source already answers `trill`, at this path:
        /// nix's own `bin/trill`, a desktop's link at the copy it placed, a
        /// cask's `binary` stanza. trill leaves all of those alone.
        case managed(String)
        /// trill placed the link, and a login shell resolves it.
        case linked(String)
        /// trill placed the link, but its directory is on nobody's PATH, so
        /// the command still doesn't resolve. A link is not an install: the
        /// difference between these two cases is the whole reason this is
        /// three states and not a Bool.
        case linkedNotOnPath(String)
        /// Nothing was placed, and why in one sentence.
        case blocked(String)
    }

    /// The directory trill puts the shim in, chosen from the PATH the user
    /// actually has.
    ///
    /// Picking a fixed directory is the obvious version and it is wrong in the
    /// common case: `~/.local/bin` is the conventional answer and is on
    /// **nobody's** PATH by default on macOS, so a fixed choice writes a file
    /// that exists and a command that never runs. So look at the login shell's
    /// own PATH first and use a directory already on it, and only fall back to
    /// `~/.local/bin` (creating it) when the PATH offers nothing usable — at
    /// which point the caller says so rather than claiming success.
    ///
    /// Only directories **under the user's home** are eligible, and never
    /// nix-managed ones. `/usr/local/bin` wants admin, and an app that raises
    /// an authorization prompt at launch to install a convenience is an app
    /// people quit.
    ///
    /// The nix exclusions are the subtle half, and the obvious spelling of
    /// them is dead code: `/nix/store`, `/etc/profiles/…` and
    /// `/run/current-system/…` are already excluded by the home check, since
    /// nothing under `$HOME` can start with them. The profile bins that
    /// actually reach a user's PATH live INSIDE home —
    /// `~/.nix-profile/bin`, `~/.local/state/nix/profile/bin` — and every one
    /// of them is a symlink chain into the read-only store: a link written
    /// there fails outright, and would be gone at the next rebuild if it
    /// didn't. Those are the names worth filtering.
    static func cliLinkDirectory(loginPath: [String], home: String) -> URL {
        let fallback = URL(fileURLWithPath: home).appendingPathComponent(".local/bin")
        let homePrefix = home.hasSuffix("/") ? home : home + "/"
        let managed = [
            homePrefix + ".nix-profile",
            homePrefix + ".local/state/nix/profile",
        ]

        let eligible = loginPath.filter { entry in
            entry.hasPrefix(homePrefix) && !managed.contains(where: entry.hasPrefix)
        }
        // Preferred first, so a machine that happens to have both gets the
        // conventional one rather than whatever came earliest on PATH.
        for preferred in [fallback.path, URL(fileURLWithPath: home).appendingPathComponent("bin").path]
        where eligible.contains(preferred) {
            return URL(fileURLWithPath: preferred)
        }
        return eligible.first.map { URL(fileURLWithPath: $0) } ?? fallback
    }

    /// What's already on disk where the shim goes.
    enum CLILinkOccupant: Equatable, Sendable {
        case nothing
        case symlink
        /// A regular file, a directory, anything that isn't a symlink.
        case other
    }

    /// What to do about the shim, decided from four facts and nothing else.
    enum CLILinkPlan: Equatable, Sendable {
        case place
        /// Something on PATH already runs THIS bundle — trill's own link from
        /// a launch when the chosen directory was a different one. Nothing to
        /// do, and emphatically not "someone else installed it".
        case alreadyOurs(String)
        case leaveAlone(String)
        case refuse(String)
    }

    /// The whole decision, as a pure function — the traps here are all about
    /// telling three near-identical situations apart, and that is exactly the
    /// kind of thing that should be testable without a filesystem.
    ///
    /// - `resolved` is what a login shell says `trill` is *today*, if anything.
    ///   Non-nil and pointing somewhere other than our own link means another
    ///   install source owns the name — nix, a desktop, a cask — and its answer
    ///   points at the bundle whose grants and socket the user actually has.
    ///   Replacing it would silently hand `trill send` a second daemon.
    /// - `resolved` equal to our own link path is the ordinary re-launch: the
    ///   thing it found is the thing we placed, so we still own it and refresh.
    static func cliLinkPlan(
        resolved: String?,
        linkPath: String,
        occupant: CLILinkOccupant,
        resolvedRunsThisBundle: Bool
    ) -> CLILinkPlan {
        if let resolved, resolved != linkPath {
            // A `trill` at some other path that nonetheless runs this very
            // bundle is one trill placed itself, earlier, when the login PATH
            // looked different — the user has since added a directory this
            // code now prefers. Reporting that as another installer's work
            // would name trill's own file as a stranger's.
            return resolvedRunsThisBundle ? .alreadyOurs(resolved) : .leaveAlone(resolved)
        }
        switch occupant {
        case .other:
            return .refuse("\(linkPath) already exists and isn't a symlink, so trill left it alone.")
        case .nothing, .symlink:
            return .place
        }
    }

    /// Make `trill` resolve on PATH, whatever installed this bundle.
    ///
    /// The app binary IS the CLI — one executable, two personalities — so a
    /// running trill has always been one symlink away from being scriptable,
    /// and for a long time nothing created it. Every install source dropped a
    /// bundle and stopped: `trill send` failed on a Mac with trill live in the
    /// menu bar, and the callers that worked worked by hunting for the bundle
    /// themselves (`holt notify` still carries that fallback list). That hunt
    /// is a reasonable thing for one Go program to do and an unreasonable
    /// thing to document as the way to use a CLI.
    ///
    /// The order matters. **Ask first, link second**: a source that ships its
    /// own `trill` — nix's `bin/trill`, a desktop linking the copy it placed
    /// at a fixed path, a cask's `binary` — owns the name, and its answer
    /// points at the bundle whose permission grants and daemon socket the
    /// user actually has. Overwriting that with a link to *this* bundle would
    /// hand `trill send` a second daemon.
    ///
    /// Never fatal, never blocking: this is a convenience, and a compositor
    /// that refused to draw because it couldn't write a symlink would have
    /// its priorities backwards.
    @discardableResult
    static func ensureCLILink(enabled: Bool) async -> CLILinkState {
        guard enabled else { return .off }

        // A Debug build must never own the name. It already carries its own
        // bundle id and its own state directory so it can't fight the
        // installed app over one TCC row or one socket (see `AppPaths`), and
        // PATH is the same class of shared resource: a build run out of an
        // agent worktree would otherwise point the user's `trill` at a
        // checkout that gets deleted when the lane is reaped, and every
        // `trill send` on the machine would start failing for a reason
        // nothing on screen explains.
        if Bundle.main.bundleIdentifier?.hasSuffix(".debug") == true {
            return .blocked("This is a Debug build, so it left the `trill` command to the installed app.")
        }

        guard let target = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            return .blocked("Trill can't tell where its own executable is.")
        }

        // Whoever answers now, answers from the user's real PATH — not this
        // process's. A login-item launch inherits launchd's environment, which
        // names none of the directories a person installs tools into, so
        // asking our own `environ` would report "nothing there" on exactly the
        // Macs where something is. One shell, both questions.
        let shell = await loginShellReading()
        let resolved = shell.resolved
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let link = cliLinkDirectory(loginPath: shell.path, home: home)
            .appendingPathComponent("trill")

        let fm = FileManager.default
        // `attributesOfItem` does NOT follow the last symlink, which is what
        // makes it the right question here: a dangling link must read as a
        // link (ours, refreshable), not as nothing.
        let occupant: CLILinkOccupant
        if let attrs = try? fm.attributesOfItem(atPath: link.path) {
            occupant = (attrs[.type] as? FileAttributeType) == .typeSymbolicLink ? .symlink : .other
        } else {
            occupant = .nothing
        }

        // Whether what already answers `trill` is in fact this bundle under
        // another name. Compared after resolving symlinks on both sides,
        // because the thing on PATH is a symlink by construction.
        let resolvedRunsThisBundle = resolved
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == target.path } ?? false

        switch cliLinkPlan(
            resolved: resolved, linkPath: link.path,
            occupant: occupant, resolvedRunsThisBundle: resolvedRunsThisBundle
        ) {
        case .alreadyOurs(let path): return .linked(path)
        case .leaveAlone(let path): return .managed(path)
        case .refuse(let reason): return .blocked(reason)
        case .place: break
        }

        do {
            try fm.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Replace rather than skip-if-present: the existing link may point
            // at a bundle that has since moved or been deleted, and a dangling
            // `trill` is worse than none — `command -v` succeeds and every
            // call fails.
            try? fm.removeItem(at: link)
            try fm.createSymbolicLink(at: link, withDestinationURL: target)
        } catch {
            log.info("cli link: \(error.localizedDescription, privacy: .public)")
            return .blocked("Couldn't write \(link.path): \(error.localizedDescription)")
        }

        // Placing the link is not the same as being reachable: a file in a
        // directory nobody's PATH names exists and never runs. Deciding from
        // the PATH we already read rather than re-running the shell — the
        // directory came out of that list, so membership is the answer.
        guard shell.path.contains(link.deletingLastPathComponent().path) else {
            return .linkedNotOnPath(link.path)
        }
        return .linked(link.path)
    }

    /// One login shell, two answers: what `trill` resolves to today, and the
    /// PATH the user actually has.
    ///
    /// `-l` is load-bearing — the profile is where PATH gets assembled, and a
    /// non-login shell would answer for an environment nobody types in. Both
    /// facts come from ONE spawn: two would cost a second rc-file evaluation
    /// at launch and could disagree.
    ///
    /// Everything about how it asks is defence against the rc file. A login
    /// shell sources `.zshenv`/`.zprofile`/`.zlogin` (or `.bash_profile`), and
    /// those routinely PRINT — a version-manager banner, a greeting, somebody's
    /// `echo`. So the answers are fenced with sentinels rather than read off
    /// fixed line numbers: one line of banner would otherwise shift the whole
    /// reading down and hand `resolved` a greeting, which the caller would
    /// dutifully treat as another installer owning the name.
    ///
    /// stdin is `/dev/null` so an rc file that reads it can't steal the
    /// terminal a development build was launched from, and the whole thing is
    /// on a deadline so an rc file that BLOCKS costs a delayed answer rather
    /// than a wedged probe and a stuck `zsh` for the life of the app.
    ///
    /// Best-effort throughout: a shell that fails, hangs, or isn't there at
    /// all yields "nothing resolves, no PATH", and the caller degrades to
    /// reporting rather than to failing.
    private static let shellProbeTimeout: TimeInterval = 10

    private static func loginShellReading() async -> (resolved: String?, path: [String]) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let timeout = shellProbeTimeout
        return await Task.detached(priority: .utility) { () -> (String?, [String]) in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: shell)
            task.arguments = [
                "-l", "-c",
                """
                printf '%s\\n' '\(commandSentinel)'
                command -v trill
                printf '%s\\n' '\(pathSentinel)'
                printf '%s\\n' "$PATH"
                """,
            ]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            task.standardInput = FileHandle.nullDevice
            do { try task.run() } catch { return (nil, []) }

            // The deadline has to kill the PROCESS, not cancel a Task:
            // `readToEnd()` blocks on a pipe that stays open for as long as
            // the shell lives, so nothing short of terminating it unblocks
            // this. SIGTERM closes the write end, the read returns whatever
            // was printed before the hang, and the parse below simply finds
            // no sentinels.
            let deadline = DispatchWorkItem { if task.isRunning { task.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)

            // Read before waiting: a shell that fills the pipe buffer while we
            // wait for it to exit deadlocks both sides.
            let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
            task.waitUntilExit()
            deadline.cancel()
            return parseShellReading(String(decoding: data, as: UTF8.self))
        }.value
    }

    /// Fences around the two answers, so rc-file chatter can't be mistaken for
    /// either. Distinctive enough that a shell printing one by coincidence is
    /// not a thing that happens.
    nonisolated private static let commandSentinel = "__trill_cli__"
    nonisolated private static let pathSentinel = "__trill_path__"

    /// Split what the login shell printed. Separate and `nonisolated` so the
    /// parsing is testable without a shell — the rc-file-noise case is the one
    /// that would silently mis-report a greeting as an installed binary.
    nonisolated static func parseShellReading(_ output: String) -> (resolved: String?, path: [String]) {
        let lines = output.components(separatedBy: "\n")
        // Last occurrence, not first: an rc file that echoed our own sentinel
        // back (a shell tracing every command, say) must not win over the real
        // one, and the real one is always the later.
        func lineAfter(_ sentinel: String) -> String? {
            guard let index = lines.lastIndex(of: sentinel), index + 1 < lines.count else { return nil }
            return lines[index + 1].trimmingCharacters(in: .whitespaces)
        }
        // `command -v` printing nothing leaves the next sentinel on that line,
        // which is exactly how "nothing resolves" is told from a real answer.
        let command = lineAfter(commandSentinel)
        let resolved = (command == pathSentinel || command?.isEmpty != false) ? nil : command
        let entries = (lineAfter(pathSentinel) ?? "")
            .split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return (resolved, entries)
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
    ///
    /// Only apps System Settings draws a row for get here. An app macOS lists
    /// no row for has no click to demonstrate and no pane to send anyone to —
    /// a step whose whole content is "you can't" — so the walkthrough never
    /// carries one. Settings says so instead, in the pane, standing still.
    static func presentNativeBannerAssistant(
        findings: [NativeNotificationSettings],
        onDismiss: (() -> Void)? = nil
    ) {
        let findings = NotificationSettingsAudit.walkable(findings)
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
