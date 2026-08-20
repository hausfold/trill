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
    /// Every on-screen window that could matter for placement, in the same
    /// bottom-left global coordinates as `ScreenDescriptor` — the window
    /// server answers in top-left coordinates, so each rect is flipped here
    /// and nowhere else.
    static func windows(on screenFrame: CGRect) -> [DesktopLayout.Window] {
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
            guard frame.intersects(screenFrame) else { return nil }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            return DesktopLayout.Window(frame: frame, isOverlay: layer != 0)
        }
    }
}

extension ScreenDescriptor {
    @MainActor
    init(screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        let windows = DesktopLayoutProbe.windows(on: screen.frame)
        self.init(
            id: (number as? NSNumber)?.stringValue ?? screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            contentFrame: DesktopLayout.anchor(
                visible: screen.visibleFrame,
                windows: windows,
                inset: BannerGeometry.inset
            )
        )
    }
}
