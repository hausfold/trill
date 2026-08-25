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
                BannerView(
                    entry: entry,
                    maxFoldRows: 0,
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
    /// no glyph, no motion — from across the room it only says "a question
    /// is waiting", and its hue says what kind.
    private var fin: some View {
        UnevenRoundedRectangle(topLeadingRadius: 4, bottomLeadingRadius: 4, style: .continuous)
            .fill(BannerTheme.current().color(for: entry.event.kind).opacity(0.9))
            .frame(
                width: BannerGeometry.Ledge.finSize.width,
                height: BannerGeometry.Ledge.finSize.height
            )
            .accessibilityElement()
            .accessibilityLabel("\(entry.event.source): \(entry.event.title), parked")
    }
}
