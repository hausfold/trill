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
            onHover: onHover,
            onDismiss: onDismiss,
            onActivate: onActivate,
            onAction: onAction
        ))
        panel.contentView = host
        panel.orderFrontRegardless()
    }

    func update(
        entry: BannerQueue.Entry,
        frame: CGRect,
        onHover: @escaping (Bool) -> Void,
        onDismiss: @escaping () -> Void,
        onActivate: @escaping () -> Void,
        onAction: @escaping (NotificationEvent.Action) -> Void
    ) {
        host.rootView = LedgeItemView(
            entry: entry,
            onHover: onHover,
            onDismiss: onDismiss,
            onActivate: onActivate,
            onAction: onAction
        )
        panel.setFrame(frame, display: true)
        // A shadow under the 8pt fin reads as grime on the screen edge; the
        // slid-out card gets the same complete shadow every banner carries.
        panel.hasShadow = entry.expanded
        panel.invalidateShadow()
    }

    func close() {
        panel.orderOut(nil)
    }
}
