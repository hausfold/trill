import AppKit

/// The compositor's one vocabulary of motion. Panels move by animating the
/// *window* frame — the SwiftUI inside is already rendered at its final size
/// and the panel reveals or covers it as it goes — so a restack, a fold
/// opening, and a fin sliding out are all the same short ease-out. Under
/// Reduce Motion every path here is instant: frames jump, departures vanish.
@MainActor
enum PanelMotion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Slides and resizes. Short enough that a hover-opened fold never feels
    /// like it is waiting on its own animation.
    private static let moveDuration: TimeInterval = 0.18
    /// Departures run a shade quicker than moves, so a card fading where it
    /// stood is gone before its neighbors finish sliding into the gap.
    private static let departDuration: TimeInterval = 0.15

    /// Animate a panel to a new frame. Instant when Reduce Motion is on or
    /// the panel isn't actually on screen to be seen moving.
    static func move(_ panel: NSPanel, to frame: CGRect, then completion: (() -> Void)? = nil) {
        guard !reduceMotion, panel.isVisible, panel.frame != frame else {
            panel.setFrame(frame, display: true)
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = moveDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        }, completionHandler: {
            completion?()
        })
    }

    /// Fade a panel out with a small directional drift, then order it out.
    /// The completion handler holds the panel alive for the animation, so
    /// callers can drop their controller immediately.
    static func depart(_ panel: NSPanel, dx: CGFloat = 0, dy: CGFloat = 0) {
        guard !reduceMotion, panel.isVisible else {
            panel.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = departDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(panel.frame.offsetBy(dx: dx, dy: dy), display: true)
        }, completionHandler: {
            panel.orderOut(nil)
        })
    }
}
