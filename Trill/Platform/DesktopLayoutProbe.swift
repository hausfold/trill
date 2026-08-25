import AppKit

/// Asks the window server what is on screen, so the compositor can put its
/// stack where the user's own windows are rather than where Apple's metrics
/// say the corner is.
///
/// **Why this exists.** `NSScreen.visibleFrame` subtracts the menu bar and
/// the Dock and nothing else. A user with the menu bar auto-hidden and a
/// third-party bar (sketchybar, Übersicht, a status HUD) has a strip macOS
/// calls free and they call occupied — banners landed on top of it. And a
/// tiling window manager leaves an outer gap that a card 12pt from the screen
/// edge visibly disagrees with by a few points, which reads as a mistake.
///
/// **What it may not become.** This reads geometry only: bounds, level, pid.
/// `CGWindowListCopyWindowInfo` will hand out window *titles* to an app the
/// user has granted Screen Recording, and trill must never ask for that — a
/// notification compositor reading window titles is exactly the thing this
/// app promises it isn't. Nothing here touches `kCGWindowName`, and the
/// permission is not requested anywhere in the codebase.
@MainActor
enum DesktopLayoutProbe {
    /// One reading of the window server, flipped into `ScreenDescriptor`
    /// coordinates — the window server answers in top-left coordinates, so
    /// each rect is flipped here and nowhere else.
    ///
    /// Taken once per render pass and shared across displays: this is the
    /// expensive call on the path, and a Mac with three monitors must not
    /// pay for it three times to draw one card.
    static func allWindows() -> [DesktopLayout.Window] {
        guard let global = NSScreen.screens.first?.frame else { return [] }
        // `.excludeDesktopElements` is deliberately NOT passed, and that is the
        // whole reason this works: sketchybar draws at `kCGBackstopMenuLevel`
        // (-20), *below* ordinary windows, so the flag that sounds like
        // "skip the wallpaper" also skips the bar we exist to stay off. The
        // wallpaper and the Dock's backdrop come through instead — both are
        // full-screen, and `DesktopLayout` throws out anything that tall as a
        // curtain rather than a bar.
        let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let ownPID = ProcessInfo.processInfo.processIdentifier

        return info.compactMap { entry -> DesktopLayout.Window? in
            // trill's own banners are on this list. Aligning to them would
            // make every card chase the one before it.
            if let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid == ownPID { return nil }
            // A fully transparent window is furniture for its own app, not
            // something the user sees an edge of.
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { return nil }
            guard let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 0, height > 0
            else { return nil }

            let frame = CGRect(
                x: x,
                y: global.maxY - (y + height),
                width: width,
                height: height
            )
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            return DesktopLayout.Window(frame: frame, isOverlay: layer != 0)
        }
    }
}

extension ScreenDescriptor {
    /// One display, measured against a window reading the caller already
    /// took — see `attached()`.
    @MainActor
    init(screen: NSScreen, windows: [DesktopLayout.Window]) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let onThisScreen = windows.filter { $0.frame.intersects(screen.frame) }
        self.init(
            id: number?.stringValue ?? screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            contentFrame: DesktopLayout.anchor(
                visible: screen.visibleFrame,
                windows: onThisScreen,
                inset: BannerGeometry.inset
            ),
            isBuiltin: number.map { CGDisplayIsBuiltin(CGDirectDisplayID($0.uint32Value)) != 0 } ?? false
        )
    }

    /// Every attached display, in the system's own order (index 0 carries the
    /// menu bar), off a single reading of the window server.
    @MainActor
    static func attached() -> [ScreenDescriptor] {
        let windows = DesktopLayoutProbe.allWindows()
        return NSScreen.screens.map { ScreenDescriptor(screen: $0, windows: windows) }
    }

    /// The display the pointer is on — what `DisplayTarget.active` means.
    ///
    /// The pointer, and not `NSScreen.main`: that is documented as the screen
    /// with the *key window*, and trill's own windows are non-activating, so
    /// on a Mac where nothing is focused it answers for the last app that
    /// was. Where the hand is is the honest reading of "the display you're
    /// facing", and it costs no permission.
    @MainActor
    static func pointerScreenID() -> String? {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) })
        else { return nil }
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.stringValue ?? screen.localizedName
    }
}
