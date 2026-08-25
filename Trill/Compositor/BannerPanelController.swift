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
    private let host: NSHostingView<PinnedCard>

    /// How a panel leaves the screen. The window system knows *why* an entry
    /// left the visible set; the exit motion is the reason made visible.
    enum Departure {
        /// Teardown (stop, topology rebuild) — re-presentation, not an event.
        case instant
        /// Dismissed or expired in place: rise the same 8pt the arrival fell.
        case dismissed
        /// An ask leaving for the ledge: drift toward the right screen edge
        /// where its fin is about to emerge.
        case parked
    }

    /// Pins the fixed-size card to the panel's top-left corner. Mid-slide the
    /// hosting view is briefly a different size than the card, and without
    /// the pin SwiftUI would center the card in it — the text would drift
    /// while the frame settles.
    struct PinnedCard: View {
        let card: BannerView
        var body: some View {
            card.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    init(
        entry: BannerQueue.Entry,
        maxFoldRows: Int,
        frame: CGRect,
        onHover: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onAction: @escaping (NotificationEvent.Action) -> Void,
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
        // Each card carries its own complete shadow — AppKit shapes it from
        // the rendered alpha, so it follows the view's rounded corners. Any
        // frame change has to invalidate it or the old outline is left behind.
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none // motion is the view's job, and it is small

        host = NSHostingView(rootView: PinnedCard(card: BannerView(
            entry: entry,
            maxFoldRows: maxFoldRows,
            onHover: onHover,
            onDismiss: onDismiss,
            onActivate: onActivate,
            onAction: onAction,
            onActivateFolded: onActivateFolded
        )))
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
        onAction: @escaping (NotificationEvent.Action) -> Void,
        onActivateFolded: @escaping (NotificationEvent) -> Void
    ) {
        host.rootView = PinnedCard(card: BannerView(
            entry: entry,
            maxFoldRows: maxFoldRows,
            onHover: onHover,
            onDismiss: onDismiss,
            onActivate: onActivate,
            onAction: onAction,
            onActivateFolded: onActivateFolded
        ))
        // A restack, a fold opening, a neighbor's slot freeing up — all the
        // same short slide. The shadow is re-shaped once the frame lands.
        PanelMotion.move(panel, to: frame) { [weak panel] in
            panel?.invalidateShadow()
        }
    }

    func close(_ departure: Departure = .instant) {
        switch departure {
        case .instant: panel.orderOut(nil)
        case .dismissed: PanelMotion.depart(panel, dy: 8)
        case .parked: PanelMotion.depart(panel, dx: 24)
        }
    }
}
