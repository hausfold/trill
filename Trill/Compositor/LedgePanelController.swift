import AppKit
import SwiftUI

/// One borderless, non-activating panel per parked ask — the fin, and the
/// full card it slides out into on hover. Same disposability contract as
/// `BannerPanelController`: all state lives in `BannerQueue.parked`, so a
/// topology rebuild closes every one of these and re-renders from the queue.
@MainActor
final class LedgePanelController {
    let entryID: String
    private let panel: NSPanel
    /// Held so updates swap `rootView` — a rebuilt hosting view would reset
    /// the card's `@State` and replay its arrival fade on every re-render.
    private let host: NSHostingView<LedgeItemView>

    init(
        entry: BannerQueue.Entry,
        shy: Bool,
        frame: CGRect,
        onHover: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onAction: @escaping (NotificationEvent.Action) -> Void
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
        panel.hasShadow = entry.expanded
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.animationBehavior = .none // parked means zero motion

        host = NSHostingView(rootView: LedgeItemView(
            entry: entry,
            shy: shy,
            onHover: onHover,
            onDismiss: onDismiss,
            onActivate: onActivate,
            onAction: onAction
        ))
        panel.contentView = host
        // A fresh fin emerges from behind the screen edge — it starts fully
        // off-screen and slides its own width into view, the ledge-side echo
        // of the banner drifting edgeward as it parked. No fade needed: the
        // edge itself is the curtain. Topology rebuilds replay this, which
        // reads as the ledge re-presenting itself.
        if !PanelMotion.reduceMotion, !entry.expanded {
            panel.setFrame(frame.offsetBy(dx: frame.width, dy: 0), display: false)
            panel.orderFrontRegardless()
            PanelMotion.move(panel, to: frame)
        } else {
            panel.orderFrontRegardless()
        }
    }

    func update(
        entry: BannerQueue.Entry,
        shy: Bool,
        frame: CGRect,
        onHover: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onAction: @escaping (NotificationEvent.Action) -> Void
    ) {
        host.rootView = LedgeItemView(
            entry: entry,
            shy: shy,
            onHover: onHover,
            onDismiss: onDismiss,
            onActivate: onActivate,
            onAction: onAction
        )
        // A shadow under the 8pt fin reads as grime on the screen edge; the
        // slid-out card gets the same complete shadow every banner carries.
        panel.hasShadow = entry.expanded
        // The fin↔card swap (a size change) lands the window instantly:
        // animating the frame under the pointer rebuilds the tracking area
        // every tick, which fires enter/exit pairs — the queue expands and
        // collapses in a loop and the fin flickers instead of opening. The
        // slide out of the edge is the *view's* job (`LedgeItemView`'s
        // trailing transition), inside a panel already at its final frame.
        // Only same-size slot moves — which no pointer is riding — animate
        // at the window layer.
        if frame.size == panel.frame.size {
            PanelMotion.move(panel, to: frame) { [weak panel] in
                panel?.invalidateShadow()
            }
        } else {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
            // Reshape the shadow again once the card's slide has landed.
            Task { [weak panel] in
                try? await Task.sleep(for: .milliseconds(250))
                panel?.invalidateShadow()
            }
        }
    }

    /// `animated` fades the fin back into the edge it came from — used when
    /// its ask is answered or evicted. Teardown paths stay instant.
    func close(animated: Bool = false) {
        if animated {
            PanelMotion.depart(panel, dx: 12)
        } else {
            panel.orderOut(nil)
        }
    }
}
