import SwiftUI

/// The banner surface. Flat, quiet, nebelung-shaped: thin source accent,
/// small symbol, no sound, no bounce, eight points of motion at most —
/// and none at all under Reduce Motion.
///
/// A coalesced banner shows the newest thread-mate on its face and a count
/// of what folded in behind it; hovering deepens that count into an actual
/// list, and every line of that list is its own button. Hover already pauses
/// the dismiss clock, so the list stays up as long as you are reading it,
/// and the banner costs nothing extra when you're not.
struct BannerView: View {
    let entry: BannerQueue.Entry
    /// Rows the fold may draw, handed down by the compositor from
    /// `BannerGeometry.foldRowCapacity`. The cap is a property of the screen
    /// and the card's place in the stack; this view knows neither, and must
    /// not learn — it only has to draw exactly the rows its height was
    /// computed for.
    let maxFoldRows: Int
    var onHover: (Bool) -> Void
    var onDismiss: () -> Void
    var onActivate: () -> Void
    /// Click on one line of the fold: that line's own event, not the face's.
    var onActivateFolded: (NotificationEvent) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrived = false
    @State private var hovering = false
    /// Index into `listedFolds` of the row under the pointer. Purely a
    /// highlight — the queue's hover (which card is expanded) is unaffected,
    /// because moving between rows never leaves the card.
    @State private var hoveredRow: Int?

    private var event: NotificationEvent { entry.event }
    private var redacted: Bool { event.privacy == .redacted }

    /// The same arithmetic the compositor sized the panel with — never a
    /// measured height (`fittingSize` lags a state change by a turn on
    /// macOS 26, and the panel would settle on the wrong number).
    private var cardSize: CGSize {
        BannerGeometry.cardSize(
            foldedCount: entry.coalescedCount,
            expanded: entry.expanded,
            maxRows: maxFoldRows
        )
    }

    private var urgencyAccent: Color {
        switch event.urgency {
        case .low: return .secondary
        case .normal: return .accentColor
        case .critical: return .red
        }
    }

    private var titleWeight: Font.Weight {
        event.urgency == .critical ? .bold : .semibold
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            face
            // `maxFoldRows` is part of the condition, not just of the
            // contents: on a screen too short to pay for a single row
            // `cardSize` returns the bare face, and a list drawn anyway —
            // even the eventless "and N earlier" line — would overflow a
            // panel that never grew.
            if entry.expanded, maxFoldRows > 0 {
                foldList
            }
        }
        .frame(width: cardSize.width, height: cardSize.height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.separator, lineWidth: 1)
                )
        )
        // Shaped for *hover* — the card has to keep the queue's hover while
        // the pointer crosses the gaps between rows, or the fold would
        // collapse under its own list. Clicking is not the card's job: the
        // face and each fold row carry their own target, because a folded
        // line that ran the face's action would be a lie about what it is.
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { inside in
            hovering = inside
            if !inside { hoveredRow = nil }
            onHover(inside)
        }
        // A thread-mate folding in while the pointer sits still shifts every
        // row down by one. The index the highlight is holding would then be a
        // different event — drop it and let the next move re-light the row
        // actually under the cursor.
        .onChange(of: entry.coalescedCount) { hoveredRow = nil }
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived || reduceMotion ? 0 : -8)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                arrived = true
            }
        }
        // `.contain`, not `.combine`: the fold rows are individually
        // actionable now, so VoiceOver has to be able to reach them. The face
        // combines into one element of its own just below.
        .accessibilityElement(children: .contain)
    }

    /// The face: what a banner has always been. Its height is fixed whether
    /// or not the fold list is showing, so expanding never reflows the part
    /// you were already reading — and the bottom `BannerGeometry.overlap`
    /// points of it are padding the next card in the stack tucks over.
    private var face: some View {
        HStack(alignment: .top, spacing: 10) {
            // Thin source accent. Hex values stay in nebelung; until the
            // palette wiring lands this rides the system accent — except
            // urgency, which always wins so critical reads as critical.
            Capsule()
                .fill(urgencyAccent)
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.source)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if entry.coalescedCount > 0 {
                        // Collapsed this is the whole receipt; expanded it is
                        // the label on the list underneath.
                        Text("+\(entry.coalescedCount) more")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    // The banner body is the click target (`performDefault`
                    // runs the first action), so a single-action event needs
                    // to *say* what clicking does — otherwise the action is
                    // real but invisible. Rides the existing row rather than
                    // adding a button row: the banner's height is fixed.
                    if let action = event.actions.first, event.actions.count == 1 {
                        Text(action.label)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.tint)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                Capsule().fill(Color.accentColor.opacity(0.14))
                            )
                    }
                    Spacer(minLength: 0)
                    if hovering {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                    }
                }

                Text(event.title)
                    .font(.title3.weight(titleWeight))
                    .lineLimit(1)

                if !redacted, let body = event.body ?? event.subtitle {
                    Text(body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            if let symbol = event.symbol {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(urgencyAccent)
                    .frame(width: 22, height: 22)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(
            width: BannerGeometry.size.width,
            height: BannerGeometry.size.height,
            alignment: .topLeading
        )
        // Stays a tap gesture rather than a `Button`: the dismiss control
        // lives inside the face, and a button inside a button is a fight over
        // the same click. Unconditional, unlike a fold row — clicking the
        // face has always also dismissed the banner, so it does something
        // even for an event carrying no action of its own.
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(faceAccessibilityText)
    }

    /// The fold, opened. One line per thread-mate, newest first, and each
    /// line is a button for *its own* event — the whole point of listing them
    /// separately is that they can be acted on separately. As many as the
    /// screen gave us; whatever is left over collapses into a single "and N
    /// earlier", so a burst of two hundred is still a glance and still fits
    /// on the display. Row heights are fixed so the total matches
    /// `BannerGeometry.cardSize` exactly.
    private var foldList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.horizontal, 12)
                .padding(.bottom, 5)

            ForEach(Array(listedFolds.enumerated()), id: \.offset) { index, folded in
                foldRow(folded, at: index)
            }

            if entry.coalescedCount > listedFolds.count {
                // Not a button: it stands for several events, so there is no
                // single thing for a click to do.
                Text("and \(entry.coalescedCount - listedFolds.count) earlier")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(height: BannerGeometry.foldRowHeight)
                    .padding(.horizontal, 12)
            }
        }
        // Divider (1) + 5 above + 6 below == BannerGeometry.foldListInset,
        // and the 6 below is what the next card tucks over.
        .padding(.bottom, 6)
    }

    /// One line of the fold. Pressable only when its event actually carries
    /// somewhere to go: trill draws no dead buttons, so a row with no default
    /// action gets no highlight, no pointer feedback, and no click. Clicking
    /// one dismisses the whole banner — you came to the fold because the
    /// thread wanted a decision, and you've just made it.
    @ViewBuilder
    private func foldRow(_ folded: NotificationEvent, at index: Int) -> some View {
        let live = folded.hasDefaultAction
        let content = HStack(spacing: 6) {
            Text(folded.title)
                .font(.caption)
                .lineLimit(1)
            // Privacy is per event, so a redacted thread-mate keeps
            // its body to itself even when the face is visible.
            if folded.privacy != .redacted, let body = folded.body ?? folded.subtitle {
                Text(body)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .frame(height: BannerGeometry.foldRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.primary.opacity(live && hoveredRow == index ? 0.09 : 0))
        )
        .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        // 6 here + 6 on the row == the face's 12, so the highlight bleeds
        // slightly wider than the text without breaking the card's margin.
        .padding(.horizontal, 6)

        if live {
            Button { onActivateFolded(folded) } label: { content }
                .buttonStyle(.plain)
                .onHover { hoveredRow = $0 ? index : (hoveredRow == index ? nil : hoveredRow) }
                .accessibilityLabel("\(folded.title). \(folded.actions.first?.label ?? "Open \(folded.source)")")
        } else {
            // A dead row still has to *clear* the highlight when the pointer
            // arrives on it — without this, crossing from a live row onto a
            // dead one leaves the live one lit under nothing.
            content
                .onHover { if $0 { hoveredRow = nil } }
                .accessibilityLabel(folded.title)
        }
    }

    /// The folded events this card names one by one — the same count the
    /// height was computed from, so the list can never outgrow the card.
    private var listedFolds: [NotificationEvent] {
        Array(entry.folded.prefix(
            BannerGeometry.foldListedCount(folded: entry.coalescedCount, maxRows: maxFoldRows)
        ))
    }

    /// The face's own spoken label. The fold rows are separate accessibility
    /// elements now (they are separate buttons), so this no longer has to
    /// recite the list — it says how much is behind the face and leaves the
    /// rows to speak for themselves.
    private var faceAccessibilityText: String {
        let head = "\(event.source): \(event.title)"
        guard entry.coalescedCount > 0 else { return head }
        return "\(head), \(entry.coalescedCount) more in this thread"
    }
}
