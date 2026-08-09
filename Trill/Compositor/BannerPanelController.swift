import AppKit
import SwiftUI

/// One borderless, non-activating panel per visible banner. Panels join all
/// Spaces and float over fullscreen apps; they never take key focus, so a
/// banner can never steal a keystroke from whatever you're typing into.
@MainActor
final class BannerPanelController {
    let entryID: String
    private let panel: NSPanel
    /// Held so updates can swap `rootView` instead of rebuilding the hosting
    /// view. A rebuild resets the view's `@State`, which would replay the
    /// arrival fade every time a banner grows, shrinks, or re-lays out.
    private let host: NSHostingView<BannerView>

    init(
        entry: BannerQueue.Entry,
        maxFoldRows: Int,
        frame: CGRect,
        onHover: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onActivateFolded: @escaping (NotificationEvent) -> Void
    ) {
        entryID = entry.id

        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Depth is what makes the overlapping cards read as a stack rather
        // than as one smeared rectangle — AppKit shapes the shadow from the
        // rendered alpha, so it follows the view's rounded corners. Any frame
        // change has to invalidate it or the old outline is left behind.
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none // motion is the view's job, and it is small

        host = NSHostingView(rootView: BannerView(
            entry: entry,
            maxFoldRows: maxFoldRows,
            onHover: onHover,
            onDismiss: onDismiss,
            onActivate: onActivate,
            onActivateFolded: onActivateFolded
        ))
        panel.contentView = host
        panel.orderFrontRegardless()

        // The view arrives at opacity 0 and fades in over 0.18s, and AppKit
        // shapes the shadow from what it actually rendered. Ask again once
        // the fade has landed, or a banner that never gets an `update` (a
        // lone one, nothing restacking it) sits there flat.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            self?.panel.invalidateShadow()
        }
    }

    func update(
        entry: BannerQueue.Entry,
        maxFoldRows: Int,
        frame: CGRect,
        onHover: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onActivateFolded: @escaping (NotificationEvent) -> Void
    ) {
        host.rootView = BannerView(
            entry: entry,
            maxFoldRows: maxFoldRows,
            onHover: onHover,
            onDismiss: onDismiss,
            onActivate: onActivate,
            onActivateFolded: onActivateFolded
        )
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
    }

    func close() {
        panel.orderOut(nil)
    }
}
