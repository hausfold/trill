import AppKit

/// Coordinates every window the user explicitly summoned from the status
/// item (Inbox, Settings): centralizes the activation dance so it can't
/// drift out of sync between windows, and isn't copy-pasted per call site.
///
/// An accessory-policy (LSUIElement) app's windows can get left ordered
/// behind whatever's already visible — especially under tiling window
/// managers like AeroSpace, which manage window placement themselves.
/// Switching to `.regular` while a window is up, activating with
/// `ignoringOtherApps`, and raising the window at `.floating` level
/// together clear that; reverting to `.accessory` once every tracked
/// window has closed keeps the app a quiet menu-bar resident the rest of
/// the time.
///
/// ⚠️ The `.floating` level is for the *raise only*, and drops back to
/// `.normal` the moment the ordering has settled. Holding it there makes
/// the window sit on top of every other app forever — including System
/// Settings, which is the one window trill's own Settings pane sends
/// people to, and which they then cannot see beside it. A summoned window
/// stays in front because it is the front app's key window, not because
/// it outranks the desktop.
///
/// This is separate from `OnboardingAssistantPanelController`, whose panel
/// is deliberately non-activating (it sits alongside System Settings,
/// which should keep focus) and so must not run through this dance.
@MainActor
final class UtilityWindowManager: NSObject, NSWindowDelegate {
    private var openWindows: Set<NSWindow> = []

    func show(_ window: NSWindow) {
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.level = .floating
        openWindows.insert(window)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        // Next runloop turn: the tiler has had its say on placement by then,
        // and from here the window behaves like any other — in front while
        // trill is frontmost, behind whatever the user switches to next.
        DispatchQueue.main.async { [weak window] in
            window?.level = .normal
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        openWindows.remove(window)
        if openWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
