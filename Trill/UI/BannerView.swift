import SwiftUI

/// The banner surface. Flat, quiet, nebelung-shaped: kind-hued glyph chip,
/// no sound, no bounce, eight points of motion at most — and none at all
/// under Reduce Motion.
///
/// **Hue says what it is, weight says how much it matters.** The event's
/// `kind` owns the color (via `BannerTheme`) and shows on the glyph chip,
/// the fold-count pill and the action pills; `urgency` owns the intensity —
/// low dims the card, normal colors only the chip, critical fills the chip
/// solid, tints the border and bolds the title. The two never fight because
/// they color different things.
///
/// A coalesced banner shows the newest thread-mate on its face and a count
/// of what folded in behind it; hovering deepens that count into an actual
/// list, and every line of that list is its own button. Hover already pauses
/// the dismiss clock, so the list stays up as long as you are reading it.
struct BannerView: View {
    let entry: BannerQueue.Entry
    /// Rows the fold may draw, handed down by the compositor from
    /// `BannerGeometry.foldRowCapacity`. The cap is a property of the screen
    /// and the card's place in the stack; this view knows neither, and must
    /// not learn — it only has to draw exactly the rows its height was
    /// computed for.
    let maxFoldRows: Int
    /// Screen-share shyness, decided by `ScreenWatchSentinel` and handed down
    /// the same way `maxFoldRows` is: the card renders what it is told. When
    /// it is on, every body on this card is held back — the face's and each
    /// fold row's — exactly as if the sender had passed `--redact`.
    let shy: Bool
    var onHover: (Bool) -> Void
    var onDismiss: () -> Void
    var onActivate: () -> Void
    /// Click on one pill of the action row: that action, not the default.
    var onAction: (NotificationEvent.Action) -> Void
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
    private var redacted: Bool { shy || event.privacy == .redacted }
    private var kindColor: Color { BannerTheme.current().color(for: event.kind) }
    private var pills: [NotificationEvent.Action] { event.pillActions }
    /// How far along, or nil for the overwhelming majority of events that
    /// aren't going anywhere. Already clamped to `0…1` by `normalized()`.
    private var progress: Double? { event.progress }

    /// The same arithmetic the compositor sized the panel with — never a
    /// measured height (`fittingSize` lags a state change by a turn on
    /// macOS 26, and the panel would settle on the wrong number).
    private var cardSize: CGSize {
        BannerGeometry.cardSize(
            foldedCount: entry.coalescedCount,
            expanded: entry.expanded,
            maxRows: maxFoldRows,
            actionCount: pills.count,
            hasProgress: progress != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            face
            if let progress {
                progressRow(progress)
            }
            if !pills.isEmpty {
                actionRow
            }
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
                        .strokeBorder(
                            event.urgency == .critical
                                ? AnyShapeStyle(kindColor.opacity(0.5))
                                : AnyShapeStyle(.separator),
                            lineWidth: 1
                        )
                )
        )
        // Low urgency is *present but ignorable*: the whole card recedes.
        .opacity(event.urgency == .low ? 0.82 : 1)
        // Shaped for *hover* — the card has to keep the queue's hover while
        // the pointer crosses the gaps between rows, or the fold would
        // collapse under its own list. Clicking is not the card's job: the
        // face, each pill and each fold row carry their own target.
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
        // `.contain`, not `.combine`: pills and fold rows are individually
        // actionable, so VoiceOver has to be able to reach them. The face
        // combines into one element of its own just below.
        .accessibilityElement(children: .contain)
    }

    /// The face: what a banner has always been. Its height is fixed whether
    /// or not the pill row or fold list is showing, so growing never reflows
    /// the part you were already reading.
    private var face: some View {
        HStack(alignment: .top, spacing: 10) {
            chip

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.source)
                        .font(.footnote.weight(.medium))
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(Self.age(of: event.timestamp, at: context.date))
                            .font(AppFont.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    if entry.coalescedCount > 0 {
                        // Collapsed this is the whole receipt; expanded it is
                        // the label on the list underneath.
                        Text("+\(entry.coalescedCount)")
                            .font(AppFont.caption.weight(.semibold))
                            .foregroundStyle(kindColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(kindColor.opacity(0.14)))
                    }
                    // Why this card has no body. Only for shyness: an event
                    // the sender marked `--redact` is redacted wherever it is
                    // drawn and has nothing situational to explain, while a
                    // card that went quiet *because the screen is being
                    // watched* has to say so, or it just looks broken.
                    if shy {
                        Image(systemName: "eye.slash")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                            .help("Hidden while the screen is being watched")
                    }
                    // The banner body is the click target (`performDefault`
                    // runs the first action), so a single-action event needs
                    // to *say* what clicking does — otherwise the action is
                    // real but invisible. Rides the existing row rather than
                    // adding a pill row: one action doesn't pay for a row.
                    if let action = event.actions.first, pills.isEmpty, event.actions.count == 1 {
                        Text(action.label)
                            .font(AppFont.caption.weight(.medium))
                            .foregroundStyle(kindColor)
                            .lineLimit(1)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(kindColor.opacity(0.14)))
                    }
                    Spacer(minLength: 0)
                    if hovering {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Dismiss")
                    }
                }

                Text(event.title)
                    .font(AppFont.title2.weight(event.urgency == .critical ? .bold : .semibold))
                    .foregroundStyle(event.urgency == .low ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                    .lineLimit(1)

                if !redacted, let body = event.body ?? event.subtitle {
                    Text(body)
                        .font(AppFont.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
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

    /// The kind chip: a 30pt rounded square whose hue *is* the event's kind,
    /// carrying the event's symbol (or the kind's own glyph when it brought
    /// none). Weight lives here too — low goes grey, critical fills solid.
    /// This replaced the 3pt accent capsule: a colored sliver read as
    /// decoration; a filled chip reads from across the room.
    private var chip: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(chipBackground)
            Image(systemName: event.symbol ?? event.kind.defaultSymbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(chipGlyph)
        }
        .frame(width: 30, height: 30)
        .padding(.top, 2)
        .accessibilityHidden(true) // the face's label already says the kind's job
    }

    private var chipBackground: Color {
        switch event.urgency {
        case .low: Color.primary.opacity(0.06)
        case .normal: kindColor.opacity(0.16)
        case .critical: kindColor
        }
    }

    private var chipGlyph: Color {
        switch event.urgency {
        case .low: .secondary
        case .normal: kindColor
        // Dark glyph on the filled chip — the one place the card goes loud.
        case .critical: .black.opacity(0.75)
        }
    }

    /// The bar. A 4pt kind-hued track under the face with the percentage
    /// beside it — the whole of what "how far along" needs to look like on a
    /// card you read in a glance from across the room.
    ///
    /// It is drawn while the screen is watched, unlike a body: a fraction is
    /// not content. "62%" says nothing about what is building, and a card
    /// that hid its bar mid-build would look broken for no privacy gained.
    private func progressRow(_ fraction: Double) -> some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color.primary.opacity(0.10))
                .frame(height: 4)
                .overlay(alignment: .leading) {
                    GeometryReader { geometry in
                        Capsule()
                            .fill(event.urgency == .low ? AnyShapeStyle(.tertiary) : AnyShapeStyle(kindColor))
                            .frame(width: geometry.size.width * fraction, height: 4)
                    }
                    .frame(height: 4)
                }
            Text(Self.percent(fraction))
                .font(AppFont.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                // Fixed so the track doesn't twitch shorter as the label
                // grows a digit — 9% to 10% is the most-watched moment of
                // any build, and the bar must not jump backwards there.
                .frame(width: 34, alignment: .trailing)
        }
        // Growth is the one motion this card is allowed; under Reduce Motion
        // it snaps, like every other animation here.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: fraction)
        .padding(.leading, 52)
        .padding(.trailing, 12)
        .frame(height: BannerGeometry.progressRowHeight)
        // The face's own label already reads the percentage out — see
        // `faceAccessibilityText`. Two elements saying "62% complete" is
        // worse than one.
        .accessibilityHidden(true)
    }

    /// 2–3 pills under the face. The first is the primary — same action the
    /// card click runs, tinted to say so; the rest stay neutral. Only
    /// performable actions get here (`pillActions`): trill draws no dead
    /// buttons.
    private var actionRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(pills.enumerated()), id: \.element.id) { index, action in
                Button { onAction(action) } label: {
                    Text(action.label)
                        .font(AppFont.caption.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(index == 0 ? kindColor : Color.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
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
            Spacer(minLength: 0)
        }
        // 12 to match the face's margin, 52 to clear the chip column so the
        // pills align with the text they belong to.
        .padding(.leading, 52)
        .padding(.trailing, 12)
        .frame(height: BannerGeometry.actionRowHeight, alignment: .top)
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
                    .font(AppFont.caption)
                    .foregroundStyle(.tertiary)
                    .frame(height: BannerGeometry.foldRowHeight)
                    .padding(.horizontal, 12)
            }
        }
        // Divider (1) + 5 above + 6 below == BannerGeometry.foldListInset.
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
                .font(AppFont.footnote)
                .lineLimit(1)
            // Privacy is per event, so a redacted thread-mate keeps
            // its body to itself even when the face is visible — and
            // shyness covers the whole list at once.
            if !shy, folded.privacy != .redacted, let body = folded.body ?? folded.subtitle {
                Text(body)
                    .font(AppFont.footnote)
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
        var head = "\(event.source): \(event.title)"
        if let progress { head += ", \(Self.percent(progress)) complete" }
        if shy { head += ", body hidden while the screen is being watched" }
        guard entry.coalescedCount > 0 else { return head }
        return "\(head), \(entry.coalescedCount) more in this thread"
    }

    /// A banner that survived a busy stack for a while must admit its age.
    /// Compact on purpose — this sits between the source slug and the fold
    /// count, and "4 minutes ago" would eat the row.
    /// `0.42` as `42%`. Rounded down, and never to 100 before the job is
    /// actually done: a card reading 100% while the build is still running is
    /// the one number on it nobody would forgive.
    static func percent(_ fraction: Double) -> String {
        let clamped = min(max(fraction, 0), 1)
        let whole = clamped == 1 ? 100 : min(Int(clamped * 100), 99)
        return "\(whole)%"
    }

    static func age(of timestamp: Date, at now: Date) -> String {
        let seconds = now.timeIntervalSince(timestamp)
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86400))d"
        }
    }
}
