import SwiftUI

/// One item on the ledge: a slim kind-hued fin while parked, the full
/// `BannerView` card while the pointer holds it out. Which state renders is
/// queue truth (`entry.expanded`), never local state — the panel's frame was
/// computed for exactly one of the two, and a view deciding for itself would
/// clip or rattle inside it.
///
/// Hover lives on the *container*, which survives the fin↔card swap. Put it
/// on the fin and expanding would destroy the very view whose exit event is
/// supposed to collapse the card again — the stranded-hover bug the queue
/// already defends against, manufactured on purpose.
struct LedgeItemView: View {
    let entry: BannerQueue.Entry
    /// Passed straight through to the card the fin slides out into — a
    /// parked ask is as readable over a shared screen as a fresh banner.
    let shy: Bool
    var onHover: (Bool) -> Void
    var onDismiss: () -> Void
    var onActivate: () -> Void
    var onAction: (NotificationEvent.Action) -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            if entry.expanded {
                // maxFoldRows 0: the slid-out card is the face and its
                // pills. A parked ask's folded thread-mates keep their
                // count pill; reading the list is the inbox's job.
                //
                // No transition here on purpose: the reveal the fin↔card
                // swap plays is `BannerView`'s own arrival fade (a fresh
                // card fades in with its 8pt settle), inside a panel that
                // jumped to its final frame. Both window-frame animation and
                // a trailing-edge slide were tried and felt worse — the
                // first thrashes hover tracking, the second stutters against
                // the rootView swaps hovering produces.
                BannerView(
                    entry: entry,
                    maxFoldRows: 0,
                    shy: shy,
                    onHover: { _ in }, // the container below owns the queue's hover
                    onDismiss: onDismiss,
                    onActivate: onActivate,
                    onAction: onAction,
                    onActivateFolded: { _ in onActivate() }
                )
            } else {
                fin
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        .contentShape(Rectangle()) // the panel is sized to exactly one state
        .onHover(perform: onHover)
    }

    /// The parked state: a kind-hued tab against the screen edge. No text,
    /// no glyph, no motion — from across the room it only says "something is
    /// waiting", and its hue says what kind.
    ///
    /// A *running job* is the one thing that moves here, and it moves once
    /// every few seconds by a hair: the tab fills from the bottom as its bar
    /// does. That is the whole reason a build parks instead of vanishing —
    /// the strip has to be able to answer "how far along" from across the
    /// room, and hovering slides out the real card with the real bar.
    private var fin: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 4, bottomLeadingRadius: 4, style: .continuous
        )
        let hue = BannerTheme.current().color(for: entry.event.kind)
        let progress = entry.event.progress

        return shape
            .fill(hue.opacity(progress == nil ? 0.9 : 0.25))
            .frame(
                width: BannerGeometry.Ledge.finSize.width,
                height: BannerGeometry.Ledge.finSize.height
            )
            .overlay(alignment: .bottom) {
                if let progress {
                    Rectangle()
                        .fill(hue.opacity(0.9))
                        .frame(height: BannerGeometry.Ledge.finSize.height * progress)
                }
            }
            .clipShape(shape)
            .accessibilityElement()
            .accessibilityLabel(label)
    }

    /// What the fin says to VoiceOver, which is the one reader that gets the
    /// percentage in words — the tab itself only fills.
    private var label: String {
        let head = "\(entry.event.source): \(entry.event.title)"
        guard let progress = entry.event.progress else { return "\(head), parked" }
        return "\(head), \(BannerView.percent(progress)) complete, parked"
    }
}
