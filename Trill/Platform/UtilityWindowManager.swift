import AppKit

/// Coordinates every window the user explicitly summoned from the status
/// item (Inbox, Settings): centralizes the activation dance so it can't
/// drift out of sync between windows, and isn't copy-pasted per call site.
///
/// An accessory-policy (LSUIElement) app's windows can get left ordered
/// behind whatever's already visible — especially under tiling window
/// managers like AeroSpace, which manage window placement themselves.
/// Switching to `.regular` while a window is up, activating with
/// `ignoringOtherApps`, and holding the window at `.floating` level
/// together clear that; reverting to `.accessory` once every tracked
/// window has closed keeps the app a quiet menu-bar resident the rest of
/// the time.
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
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        openWindows.remove(window)
        if openWindows.isEmpty {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
