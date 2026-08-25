import SwiftUI

/// One row of the inbox: a thread folded into its newest event, or a single
/// event that never had a thread.
///
/// Shares the banner's vocabulary on purpose — kind-hued chip, kind-hued
/// count pill, the same pill row — because it is the same event, and a thing
/// that looked one way when it interrupted you should not be unrecognisable
/// an hour later. What it does *not* share is the banner's discipline: a card
/// is a glance and stops at three actions, and this is where the rest of them
/// survive (`InboxList.pills`).
struct InboxRowView: View {
    let row: InboxRow
    /// Shared clock, so every age in the list moves together and no row owns
    /// a timer of its own.
    let now: Date
    let expanded: Bool
    /// Asks still hanging on the ledge right now (`InboxFeed.parkedIDs`).
    let onLedge: Set<String>
    /// False when there is no router behind this window — then no pills are
    /// drawn at all, rather than pills that do nothing.
    let canAct: Bool
    var onOpen: () -> Void
    var onAction: (NotificationEvent.Action, NotificationEvent) -> Void
    var onToggleRead: () -> Void

    @State private var hovering = false

    private var event: NotificationEvent { row.face.event }
    private var kindColor: Color { BannerTheme.current().color(for: event.kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            face
            if expanded {
                mates
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button(row.isUnread ? "Mark as Read" : "Mark as Unread", action: onToggleRead)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Face

    private var face: some View {
        HStack(alignment: .top, spacing: 10) {
            unreadDot
            chip
            VStack(alignment: .leading, spacing: 3) {
                meta
                Text(event.title)
                    .font(.headline)
                    .foregroundStyle(row.isUnread ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let body = event.body ?? event.subtitle {
                    Text(body)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if canAct, !InboxList.pills(for: event).isEmpty {
                    pillRow(for: event)
                }
            }
            Spacer(minLength: 0)
            if row.isThread {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 2)
        // A tap gesture and not a Button: the pill row lives inside this, and
        // a button inside a button is a fight over one click. Same reason the
        // banner's face is a gesture.
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityText)
    }

    /// The one mark that says "trill never put this in front of you". Kept as
    /// a dot in its own column so titles line up whether or not it is there —
    /// an inbox whose text shifts sideways as you read it is a worse inbox.
    private var unreadDot: some View {
        Circle()
            .fill(row.isUnread ? AnyShapeStyle(kindColor) : AnyShapeStyle(.clear))
            .frame(width: 7, height: 7)
            .padding(.top, 12)
            .accessibilityHidden(true)
    }

    /// The banner's kind chip, one size down. Hue is the kind, weight is the
    /// urgency — the same two axes, so a fault reads as a fault here too.
    private var chip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(event.urgency == .critical ? kindColor : kindColor.opacity(0.16))
            Image(systemName: event.symbol ?? event.kind.defaultSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    event.urgency == .critical ? AnyShapeStyle(.black.opacity(0.75)) : AnyShapeStyle(kindColor)
                )
        }
        .frame(width: 26, height: 26)
        .padding(.top, 2)
        .accessibilityHidden(true)
    }

    private var meta: some View {
        HStack(spacing: 6) {
            Text(event.source)
                .font(.caption.weight(.medium))
                .monospaced()
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(BannerView.age(of: event.timestamp, at: now))
                .font(.caption)
                .foregroundStyle(.tertiary)
            if row.isThread {
                countPill
            }
            if onLedge.contains(event.id) {
                ledgeMark
            }
            if let label = deliveryLabel {
                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.05)))
            }
            Spacer(minLength: 0)
        }
    }

    /// How many events this row stands for — the banner's `+N`, except the
    /// inbox counts the whole thread including the face, because here the
    /// number labels a list you are about to open rather than a fold you
    /// can't see into.
    private var countPill: some View {
        Text("\(row.entries.count)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(kindColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(kindColor.opacity(0.14)))
            .accessibilityLabel("\(row.entries.count) in this thread")
    }

    /// A miniature of the ledge's own fin, for an ask still hanging on the
    /// edge of the screen. This is what makes the inbox a credible overflow:
    /// the sixth ask that evicted the first is here *with* a fin, the first
    /// is here without one, and the difference is visible rather than implied.
    private var ledgeMark: some View {
        HStack(spacing: 4) {
            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, style: .continuous)
                .fill(kindColor.opacity(0.9))
                .frame(width: 4, height: 11)
            Text("on the ledge")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .accessibilityElement()
        .accessibilityLabel("still parked on the ledge")
    }

    /// Why this is only in the inbox. A banner needs no explanation — you
    /// saw it — so only the quiet routes are named, and only where the scope
    /// isn't already the answer.
    private var deliveryLabel: String? {
        switch row.face.decision {
        case "inbox": "quiet"
        case let decision where decision.hasPrefix("digest:"):
            "digest · \(decision.dropFirst("digest:".count))"
        default: nil
        }
    }

    // MARK: - Pills

    private func pillRow(for event: NotificationEvent) -> some View {
        // Wrapping, not clipped: the banner's row is a fixed-height strip
        // because the card's height was computed for it, and this one has no
        // such promise to keep — so a fifth action moves to a second line
        // instead of falling off the end.
        FlowLayout(spacing: 6) {
            ForEach(Array(InboxList.pills(for: event).enumerated()), id: \.element.id) { index, action in
                Button { onAction(action, event) } label: {
                    Text(action.label)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(index == 0 ? kindColor : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(
                                index == 0
                                    ? AnyShapeStyle(kindColor.opacity(0.14))
                                    : AnyShapeStyle(Color.primary.opacity(0.06))
                            )
                        )
                        .overlay(
                            Capsule().strokeBorder(
                                index == 0 ? kindColor.opacity(0.3) : Color.primary.opacity(0.08),
                                lineWidth: 1
                            )
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.label)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Thread

    /// The rest of the thread, oldest-of-the-newest first — the same order
    /// the banner's fold lists them in. Each mate keeps its own pills: the
    /// whole reason to list a thread rather than count it is that its members
    /// can be acted on separately.
    private var mates: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(row.mates) { mate in
                HStack(alignment: .top, spacing: 8) {
                    Circle()
                        .fill(mate.isUnread ? AnyShapeStyle(kindColor) : AnyShapeStyle(.clear))
                        .frame(width: 5, height: 5)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(mate.event.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Text(BannerView.age(of: mate.event.timestamp, at: now))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 0)
                        }
                        if let body = mate.event.body ?? mate.event.subtitle {
                            Text(body)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        if canAct, !InboxList.pills(for: mate.event).isEmpty {
                            pillRow(for: mate.event)
                        }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
            }
        }
        // Lines up under the title column: 7 (dot) + 10 + 26 (chip) + 10.
        .padding(.leading, 53)
        .padding(.top, 4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(kindColor.opacity(0.25))
                .frame(width: 2)
                .padding(.leading, 44)
                .padding(.vertical, 2)
        }
    }

    private var accessibilityText: String {
        var parts = ["\(event.source): \(event.title)"]
        if row.isThread { parts.append("\(row.entries.count) in this thread") }
        if row.unreadCount > 0 { parts.append("\(row.unreadCount) unread") }
        if onLedge.contains(event.id) { parts.append("still parked on the ledge") }
        return parts.joined(separator: ", ")
    }
}

/// A left-aligned wrap: lay children out in a line, drop to the next when the
/// width runs out. Exists because the inbox draws *every* performable action
/// and a `HStack` would push the fifth one off the edge — the banner never
/// needs this, because its card is sized for exactly three.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = lines(within: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for line in lines(within: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(within maxWidth: CGFloat, subviews: Subviews) -> [Line] {
        var result: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, advance > maxWidth {
                result.append(current)
                current = Line()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = advance
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { result.append(current) }
        return result
    }
}
