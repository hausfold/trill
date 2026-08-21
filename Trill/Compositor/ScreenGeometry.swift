import Foundation

/// Pure description of a display — the compositor's geometry consumes this,
/// never `NSScreen`, so placement is unit-testable without an attached
/// display (perch's `ScreenDescriptor` move).
struct ScreenDescriptor: Sendable, Equatable {
    var id: String
    /// Full screen bounds in global (bottom-left-origin) coordinates.
    var frame: CGRect
    /// Bounds minus menu bar / Dock — banners never overlap either.
    var visibleFrame: CGRect
    /// Where the desktop's *own* windows sit on this display: the rect a
    /// third-party bar and the window manager's gaps have already been
    /// subtracted from. `nil` when nothing could be measured, in which case
    /// placement falls back to `visibleFrame` inset by `BannerGeometry.inset`.
    ///
    /// This exists because `visibleFrame` only knows about Apple's furniture.
    /// A user running sketchybar (or any overlay bar) with the menu bar
    /// auto-hidden has a strip at the top of the screen that macOS considers
    /// free real estate and they consider occupied — and a tiling WM leaves a
    /// gap that a banner flush to the corner visibly disagrees with. See
    /// `DesktopLayout`.
    var contentFrame: CGRect?
}

/// Reads the desktop the user actually arranged — overlay bars and the top
/// right window's own corner — and hands the compositor a rect to align to.
/// Pure: the platform probe (`DesktopLayoutProbe`) collects the rects, this
/// decides what they mean, so every rule here is testable without a display.
enum DesktopLayout {
    /// One on-screen window, as much of it as placement cares about.
    struct Window: Sendable, Equatable {
        /// Bottom-left-origin global coordinates, like `ScreenDescriptor`.
        var frame: CGRect
        /// Anything not at the normal window level: a bar, a HUD, a panel —
        /// furniture rather than content. Banners keep off it; they never
        /// align to it.
        var isOverlay: Bool
    }

    /// A bar is an overlay that spans nearly the whole width of the display
    /// and hugs one of its edges. Narrower than this and it is a HUD, which
    /// banners are allowed to overlap.
    static let barWidthShare: CGFloat = 0.8
    /// A bar is also *short*. Anything taller is a curtain — a fullscreen
    /// overlay, a wallpaper app — and subtracting it would leave no screen.
    static let barHeightShare: CGFloat = 0.25
    /// Slack when asking whether an edge touches an edge. Bars are commonly
    /// a point or two off from where their config says they are.
    static let edgeTolerance: CGFloat = 2
    /// Smaller than this in either direction and a window is a palette, a
    /// tooltip or a progress sheet — not something a banner should line up
    /// with.
    static let minimumWindowSide: CGFloat = 200

    /// `visibleFrame` minus any bar hugging its top or bottom edge. This is
    /// the "don't cover sketchybar" rule, and it is deliberately written
    /// against *shape*, not against any one app's name: trill has no business
    /// knowing which bar its user runs.
    static func usableFrame(visible: CGRect, windows: [Window]) -> CGRect {
        var top = visible.maxY
        var bottom = visible.minY

        for window in windows where window.isOverlay {
            let frame = window.frame
            guard frame.width >= visible.width * barWidthShare,
                  frame.height <= visible.height * barHeightShare,
                  frame.intersects(visible)
            else { continue }
            if frame.maxY >= visible.maxY - edgeTolerance {
                top = min(top, frame.minY)
            }
            if frame.minY <= visible.minY + edgeTolerance {
                bottom = max(bottom, frame.maxY)
            }
        }

        guard top - bottom > 0 else { return visible }
        return CGRect(x: visible.minX, y: bottom, width: visible.width, height: top - bottom)
    }

    /// The rect banners lay themselves out inside. When an ordinary window is
    /// open in the top half of the display, that window's own top-right
    /// corner *is* the anchor — so the stack reads as one more pane of the
    /// layout rather than as something pasted over it. With nothing to line
    /// up with, it falls back to the usable frame inset all round.
    ///
    /// A window taller than the usable frame is ignored: it is fullscreen, or
    /// it is sitting over the bar, and either way its corner is not a gap the
    /// user chose.
    static func anchor(visible: CGRect, windows: [Window], inset: CGFloat) -> CGRect {
        let usable = usableFrame(visible: visible, windows: windows)
        let aligned = windows
            .filter { window in
                !window.isOverlay
                    && window.frame.width >= minimumWindowSide
                    && window.frame.height >= minimumWindowSide
                    && window.frame.maxY >= usable.midY
                    && window.frame.maxY <= usable.maxY + edgeTolerance
                    && window.frame.intersects(usable)
            }
            .max { $0.frame.maxX < $1.frame.maxX }

        guard let corner = aligned?.frame else {
            return usable.insetBy(dx: inset, dy: inset)
        }
        let top = min(corner.maxY, usable.maxY)
        let right = min(corner.maxX, usable.maxX)
        let bottom = max(min(corner.minY, top), usable.minY)
        return CGRect(x: usable.minX, y: bottom, width: right - usable.minX, height: top - bottom)
    }
}

/// Where banners live and how they stack. Top-right, dealt downward like a
/// deck — clamped to the visible frame, deliberately *near* Apple's geometry
/// so muscle memory holds, without gluing to their exact metrics.
///
/// **Why a deck and not a list.** Distinct banners used to sit in separate
/// rects 8pt apart, which read as a form, not as a pile of things that
/// arrived. Each card now laps a few points *over* the card above it, and
/// every panel casts a real shadow — so a run of banners reads as one stack
/// with depth. The z-order comes free: panels are created newest-last and
/// `orderFrontRegardless` puts each new one in front, so a newer card (lower
/// on screen) covers the bottom edge of its elder — dealt, not shuffled.
/// This is a deliberate look, not an accident of spacing.
enum BannerGeometry {
    /// The card's full height *including* the strip its successor laps over
    /// — the reading area is `height - overlap`, which is the number that
    /// used to be the whole card. Grow both together or text starts clipping.
    static let size = CGSize(width: 360, height: 92)
    static let inset: CGFloat = 12

    /// How far each card laps over the one above it. Small on purpose: the
    /// covered strip is the elder card's bottom padding, and anything much
    /// larger starts eating a two-line body.
    static let overlap: CGFloat = 6

    /// Lateral step per card, each one deeper in the stack sitting this much
    /// further *left*. **Deliberately zero.** A fanned version went to a
    /// feel-test first and the drift read as misalignment rather than as
    /// depth — and it only gets worse the deeper the stack goes. The lap and
    /// the shadow carry the effect on their own. Kept as a knob, at 0, so the
    /// idea isn't rediscovered and re-shipped.
    static let step: CGFloat = 0

    // MARK: - Where the stack sits

    /// The rect the whole stack lays itself out inside — every other function
    /// here measures from this and never from `visibleFrame` directly.
    ///
    /// It is the desktop's own window grid when the platform could measure one
    /// (`ScreenDescriptor.contentFrame`), so the top card's corner lands on the
    /// same corner the user's top-right window has: clear of an overlay bar,
    /// and in the window manager's gap rather than 12pt from a screen edge
    /// nobody's windows use. With nothing measured it is the visible frame
    /// inset all round, which is the behaviour that shipped first.
    static func anchor(on screen: ScreenDescriptor) -> CGRect {
        screen.contentFrame ?? screen.visibleFrame.insetBy(dx: inset, dy: inset)
    }

    // MARK: - Expanded folds

    /// A hovered banner with folded thread-mates grows a list of them (see
    /// `BannerView`). These metrics are the contract between that view and
    /// the panel that has to be resized around it: the height is *computed*,
    /// never measured, because `NSHostingView.fittingSize` is stale in the
    /// same turn as the state change that grows the view.
    static let foldRowHeight: CGFloat = 20
    /// Divider plus the padding above and below the list. The bottom share of
    /// it is at least `overlap`, so the card below still has only padding to
    /// tuck over once a fold is open.
    static let foldListInset: CGFloat = 12

    /// The most rows a card at `index` in the stack can grow before its own
    /// bottom edge leaves the visible frame. **This is the cap — there is no
    /// magic row count.** A ten-message thread lists all ten because ten fit;
    /// a two-hundred-message one lists what fits and admits the rest in a
    /// single "and N earlier" line, because a card taller than the display is
    /// worse than no card at all.
    ///
    /// Only the *collapsed* cards above the hovered one are counted against
    /// it. Cards below are allowed to be pushed off screen: they are still in
    /// the queue and come straight back on unhover, and letting the fold stop
    /// growing at whatever happens to be beneath it would make the same burst
    /// a different height depending on unrelated traffic.
    static func foldRowCapacity(on screen: ScreenDescriptor, index: Int) -> Int {
        guard index >= 0 else { return 0 }
        let area = anchor(on: screen)
        let top = area.maxY - CGFloat(index) * (size.height - overlap)
        let room = top - area.minY - size.height - foldListInset
        guard room >= foldRowHeight else { return 0 }
        return Int(room / foldRowHeight)
    }

    /// Folded events the expanded list names one by one, given the total rows
    /// the card has height for. When the fold outruns the rows, one of them is
    /// spent on the "and N earlier" line rather than on a name — the count has
    /// to stay honest even when the list can't.
    static func foldListedCount(folded: Int, maxRows: Int) -> Int {
        let rows = max(maxRows, 0)
        guard folded > 0, rows > 0 else { return 0 }
        return folded > rows ? rows - 1 : folded
    }

    /// Rows the expanded list draws — the named ones plus, when the fold has
    /// more behind them, the single "and N earlier" line. The view draws its
    /// rows off these two functions rather than repeating the arithmetic: the
    /// card's height is fixed, so a disagreement between the two would clip a
    /// row silently instead of failing.
    static func foldRowCount(folded: Int, maxRows: Int) -> Int {
        let listed = foldListedCount(folded: folded, maxRows: maxRows)
        guard folded > 0, maxRows > 0 else { return 0 }
        return listed + (folded > listed ? 1 : 0)
    }

    /// Size of one card. Collapsed is always `size`; expanded adds exactly
    /// the fold list's rows, so the panel and the view agree on the number
    /// without either of them measuring anything. `maxRows` comes from
    /// `foldRowCapacity` — the view is handed it rather than deriving it,
    /// because the view must not know what screen it is on.
    static func cardSize(foldedCount: Int, expanded: Bool, maxRows: Int) -> CGSize {
        let rows = expanded ? foldRowCount(folded: foldedCount, maxRows: maxRows) : 0
        guard rows > 0 else { return size }
        return CGSize(
            width: size.width,
            height: size.height + foldListInset + CGFloat(rows) * foldRowHeight
        )
    }

    // MARK: - Placement

    /// How many banners fit on this screen without escaping the visible
    /// frame. The queue holds anything beyond this — resize/topology changes
    /// shrink the visible set, never lose events. Counted for collapsed
    /// cards: expanding one is a hover-scoped event, and a card the expansion
    /// pushes off screen is dropped by the compositor and comes straight back
    /// on unhover.
    static func capacity(on screen: ScreenDescriptor, bannerSize: CGSize = size) -> Int {
        let usable = anchor(on: screen).height
        guard usable >= bannerSize.height else { return 0 }
        let advance = max(1, bannerSize.height - overlap)
        return 1 + Int((usable - bannerSize.height) / advance)
    }

    /// Frames for a whole stack, index 0 topmost, in the same global
    /// coordinate space as the descriptor. Cards may differ in height (a
    /// hovered fold expands), so placement is cumulative rather than a closed
    /// form. A card that would escape the visible frame — and every card
    /// after it, since it only gets worse — comes back nil.
    static func stackFrames(on screen: ScreenDescriptor, sizes: [CGSize]) -> [CGRect?] {
        let area = anchor(on: screen)
        var frames: [CGRect?] = []
        var top = area.maxY
        var escaped = false

        for (index, cardSize) in sizes.enumerated() {
            let x = area.maxX - cardSize.width - CGFloat(index) * step
            let frame = CGRect(
                origin: CGPoint(x: x, y: top - cardSize.height),
                size: cardSize
            )
            // Only the vertical bound can rule a card out. A card is wider
            // than the anchor whenever the window it lines up with is narrow,
            // and hanging past that window's left edge is fine — running off
            // the bottom of the display is not.
            escaped = escaped || frame.minY < area.minY - 0.5
            frames.append(escaped ? nil : frame)
            top -= cardSize.height - overlap
        }
        return frames
    }

    /// Frame for the banner at `index` (0 = topmost) in a stack of uniform
    /// cards. Returns nil when the slot would leave the visible frame.
    static func slotFrame(
        on screen: ScreenDescriptor,
        index: Int,
        bannerSize: CGSize = size
    ) -> CGRect? {
        guard index >= 0, index < capacity(on: screen, bannerSize: bannerSize) else { return nil }
        return stackFrames(
            on: screen,
            sizes: Array(repeating: bannerSize, count: index + 1)
        )[index]
    }
}
