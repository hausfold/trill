import AppKit
import SwiftUI

/// Entry point. One binary, two personalities (the pounce trick):
///
///   `Trill.app` launched normally  → the LSUIElement daemon + compositor;
///   `trill send --title …`         → a short-lived CLI talking to the
///                                    daemon's socket, no NSApplication.
///
/// The `trill` command on PATH is a shim to
/// `Trill.app/Contents/MacOS/Trill`, installed by the rice.
@main
enum TrillMain {
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if let first = arguments.first, TrillCLI.subcommands.contains(first) {
            exit(TrillCLI.run(arguments: arguments))
        }

        let app = NSApplication.shared
        let delegate = TrillAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // belt-and-braces with LSUIElement
        app.run()
    }
}

/// AppKit-only, so the whole delegate lives on the main actor — the `@objc`
/// menu selectors touch `AppRuntime` (itself `@MainActor`) and would otherwise
/// be inferred `nonisolated`.
@MainActor
final class TrillAppDelegate: NSObject, NSApplicationDelegate {
    private var runtime: AppRuntime?
    private var inboxWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private let windowManager = UtilityWindowManager()
    /// Set when the FDA assistant sees the grant land, read once by the
    /// Disarms `reopenSettingsOnLaunch` when the grant landed and the process
    /// was never actually restarted (Apple's "Later" button).
    private var reopenDisarmTask: Task<Void, Never>?
    /// True once the assistant's probe saw Full Disk Access land, so a helper
    /// closing because it succeeded can be told apart from one the user shut.
    private var fdaGrantLanded = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let runtime = AppRuntime()
        self.runtime = runtime
        runtime.start()
        installStatusItem()

        // Only ever set by the Full Disk Access assistant, so a launch that
        // sees it is the relaunch straight out of Apple's "Quit & Reopen" —
        // which makes this the first moment the user can be shown the unlock.
        if runtime.settings.reopenSettingsOnLaunch {
            presentSettings(celebrateUnlock: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // CFPreferences' flush is async and nothing waits for it on the way
        // out — and if the relaunch watchdog fires, the next launch has to
        // find the settings this flow just wrote.
        UserDefaults.standard.synchronize()
        runtime?.stop()
    }

    /// Quiet by default: a template glyph, an inbox, settings, quit.
    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "circle.dotted",
            accessibilityDescription: "Trill"
        )

        let menu = NSMenu()
        menu.addItem(withTitle: "Inbox", action: #selector(showInbox), keyEquivalent: "i").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Trill", action: #selector(quitTrill), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
    }

    /// The one quit trill must treat as final: whatever the Full Disk Access
    /// flow armed, a user picking Quit means it. Disarming here is what keeps
    /// the relaunch watchdog from resurrecting an app somebody just closed.
    @objc private func quitTrill() {
        SystemIntegration.disarmRelaunchWatchdog()
        NSApp.terminate(nil)
    }

    @objc private func showInbox() {
        inboxWindow?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(
            rootView: InboxView(database: runtime?.inboxDatabase)
        )
        inboxWindow = window
        windowManager.show(window)
    }

    @objc private func showSettings() {
        presentSettings(celebrateUnlock: false)
    }

    /// `celebrateUnlock` is true only on the hop back from the Full Disk
    /// Access assistant right after the grant landed — Settings then opens
    /// with the System Mirror row briefly highlighted, so the payoff is
    /// visible instead of just being "the card changed while you were away".
    private func presentSettings(celebrateUnlock: Bool) {
        guard let runtime else { return }
        runtime.settings.reopenSettingsOnLaunch = false
        Task { @MainActor in
            let status = await runtime.providerStatusSnapshot()
            settingsWindow?.close()

            // A deterministic frame, not one measured off SwiftUI's
            // fittingSize (which can read stale content from the same run
            // loop turn as a @State change) — an unsized NSWindow shows
            // only its titlebar, which is the bug this replaced. Form's
            // own scrolling absorbs any content taller than this.
            //
            // contentView (NSHostingView), not contentViewController
            // (NSHostingController) — the controller variant auto-resizes
            // the window to the view's "preferred content size" once
            // layout settles, which for a Form without a fixed height
            // collapses it back down to titlebar-only, silently undoing
            // this frame.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Trill Settings"
            window.contentView = NSHostingView(
                rootView: SettingsView(
                    settings: runtime.settings,
                    providerStatus: status,
                    fetchProviderStatus: { [weak runtime] in
                        await runtime?.providerStatusSnapshot() ?? [:]
                    },
                    onRequestFullDiskAccess: { [weak self] in
                        self?.presentFullDiskAccessAssistant(runtime: runtime)
                    },
                    onRequestAuditAccess: { [weak self] in
                        self?.presentFullDiskAccessAssistant(runtime: runtime, enablesSystemMirror: false)
                    },
                    listedApps: { [weak runtime] in runtime?.listedApps ?? [] },
                    celebrateUnlock: celebrateUnlock
                )
            )
            settingsWindow = window
            windowManager.show(window)
        }
    }

    /// `enablesSystemMirror` is what tells the two callers apart. The grant is
    /// the same one either way, but only the System Mirror button is a request
    /// to *turn that provider on* — the audit needs the grant and nothing
    /// else, and switching an experimental provider on because someone wanted
    /// `doctor` to work would be trill answering a question it wasn't asked.
    private func presentFullDiskAccessAssistant(runtime: AppRuntime, enablesSystemMirror: Bool = true) {
        runtime.settings.reopenSettingsOnLaunch = true
        fdaGrantLanded = false
        reopenDisarmTask?.cancel()
        // Armed for the whole flow, not just after the grant: Apple's
        // "Quit & Reopen" sheet can appear the moment the switch is flipped,
        // and its quit is what this catches.
        SystemIntegration.armRelaunchWatchdog()
        // Order is load-bearing: closing the Settings window first drops
        // the app back to `.accessory` (UtilityWindowManager), and an
        // accessory app has no active-app status to hand over — macOS then
        // launches System Settings *behind* whatever was in front, which
        // under AeroSpace means behind the tile the user is staring at. So
        // open the deep link while trill is still the frontmost regular
        // app, and tidy our own window up on the next runloop turn.
        // No `onDismiss`. Reopening Settings here is a leftover from the
        // flow that relaunched trill itself: now that the helper closes the
        // instant the grant lands, macOS is *still* showing its own
        // "Quit & Reopen" sheet — and a settings window raising itself over
        // that sheet buries the thing the user has to answer. Closing to
        // nothing hands System Settings back its own screen. The relaunch
        // path still shows Settings, from `applicationDidFinishLaunching`.
        SystemIntegration.presentFullDiskAccessAssistant(
            onGrantConfirmed: { [weak self] in
                if enablesSystemMirror {
                    runtime.settings.systemMirrorEnabled = true
                }
                self?.fdaGrantLanded = true
            },
            onDismiss: { [weak self] in
                guard let self else { return }
                // Closed without a grant: nothing is coming, stand the flag
                // down now. Closed *because* the grant landed: Apple's
                // "Quit & Reopen" sheet is still on screen behind us, so keep
                // it armed long enough to cover an answer to it.
                disarmReopenOnLaunch(runtime: runtime, after: fdaGrantLanded ? 300 : 0)
            }
        )
        DispatchQueue.main.async { [weak self] in
            self?.settingsWindow?.close()
        }
    }

    /// `reopenSettingsOnLaunch` does double duty: it's what makes the
    /// post-relaunch Settings window appear, *and* what authorises
    /// `applicationWillTerminate` to finish Apple's "Quit & Reopen". Both
    /// only make sense while that sheet could still be answered — if the user
    /// takes the "Later" branch no relaunch ever comes, and left armed the
    /// flag would pop Settings open during some unrelated launch weeks later.
    private func disarmReopenOnLaunch(runtime: AppRuntime, after seconds: UInt64) {
        reopenDisarmTask?.cancel()
        guard seconds > 0 else {
            runtime.settings.reopenSettingsOnLaunch = false
            return
        }
        reopenDisarmTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            runtime.settings.reopenSettingsOnLaunch = false
            SystemIntegration.disarmRelaunchWatchdog()
        }
    }
}
