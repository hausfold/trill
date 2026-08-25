import AppKit
import SwiftUI

/// The "⌄ N waiting" tag under the bottom banner. Pure report: it takes no
/// clicks, holds no state, and lives only while the queue actually holds
/// something back — so it gets a plain panel of its own rather than a slot
/// in the stack's layout, and dipping a few points below the bottom card is
/// deliberate (a badge sits *on* the thing it counts).
@MainActor
final class OverflowBadgeController {
    private let panel: NSPanel
    private let host: NSHostingView<OverflowBadgeView>

    /// Height of the tag, and how far it hangs below the card it clings to.
    static let height: CGFloat = 20
    static let droop: CGFloat = 8

    init(count: Int, under cardFrame: CGRect) {
        panel = NSPanel(
            contentRect: Self.frame(count: count, under: cardFrame),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true // a report, never a target
        panel.animationBehavior = .none

        host = NSHostingView(rootView: OverflowBadgeView(count: count))
        panel.contentView = host
        panel.orderFrontRegardless()
    }

    func update(count: Int, under cardFrame: CGRect) {
        host.rootView = OverflowBadgeView(count: count)
        // Rides the same slide as the card it clings to, or it would snap to
        // the bottom card's destination while the card is still en route.
        PanelMotion.move(panel, to: Self.frame(count: count, under: cardFrame)) { [weak panel] in
            panel?.invalidateShadow()
        }
    }

    func close() {
        panel.orderOut(nil)
    }

    /// Trailing-aligned under the card, drooping over its bottom edge. Width
    /// scales roughly with the digit count so the panel never clips the text;
    /// the view centers itself in whatever it gets.
    private static func frame(count: Int, under cardFrame: CGRect) -> CGRect {
        let width: CGFloat = 84 + CGFloat(String(count).count) * 7
        return CGRect(
            x: cardFrame.maxX - width - 12,
            y: cardFrame.minY - droop,
            width: width,
            height: height
        )
    }
}

struct OverflowBadgeView: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
            Text("\(count) waiting")
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .frame(height: OverflowBadgeController.height)
        .background(
            Capsule().fill(.regularMaterial)
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel("\(count) notifications waiting")
    }
}
