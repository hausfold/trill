import AppKit

/// The compositor: consumes the queue's visible set and keeps exactly those
/// panels on screen. Rebuilds on every display-topology change (perch's
/// pattern); because event state lives in `BannerQueue`, a rebuild is pure
/// re-presentation — nothing queued or visible is ever lost to an unplugged
/// monitor.
@MainActor
final class BannerWindowSystem {
    private let queue: BannerQueue
    private let actionRouter: ActionRouter
    /// Screen-share shyness. A change here is a *rendering* change and
    /// nothing else — the queue never learns about it, and re-rendering from
    /// queue state is the same move a display-topology change makes.
    private let watch: ScreenWatchSentinel
    private var panels: [String: BannerPanelController] = [:]
    private var screenObserver: NSObjectProtocol?

    init(
        queue: BannerQueue,
        actionRouter: ActionRouter,
        watch: ScreenWatchSentinel = .shared
    ) {
        self.queue = queue
        self.actionRouter = actionRouter
        self.watch = watch
        queue.onVisibleChanged = { [weak self] entries in
            self?.render(entries)
        }
        queue.onParkedChanged = { [weak self] entries in
            self?.renderLedge(entries)
        }
        watch.onShyChanged = { [weak self] _ in
            guard let self else { return }
            self.render(self.queue.visible)
            self.renderLedge(self.queue.parked)
        }
    }

    func start() {
        syncCapacity()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Tear down and re-render from queue state on the new topology.
                self.panels.values.forEach { $0.close() }
                self.panels.removeAll()
                self.ledgePanels.values.forEach { $0.close() }
                self.ledgePanels.removeAll()
                self.syncCapacity()
                self.render(self.queue.visible)
                self.renderLedge(self.queue.parked)
            }
        }
    }

    func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        screenObserver = nil
        panels.values.forEach { $0.close() }
        panels.removeAll()
        ledgePanels.values.forEach { $0.close() }
        ledgePanels.removeAll()
        overflowBadge?.close()
        overflowBadge = nil
        queue.onVisibleChanged = nil
        queue.onParkedChanged = nil
        watch.onShyChanged = nil
        watch.setPolling(false)
    }

    /// Banners live on the screen with the menu bar (`NSScreen.screens
    /// .first`), matching where the system draws its own. Per-display
    /// routing is a planned extension — the queue/panel split already
    /// supports it.
    private var targetScreen: ScreenDescriptor? {
        NSScreen.screens.first.map(ScreenDescriptor.init(screen:))
    }

    /// Every card's collapsed footprint — the face plus its pill row when
    /// the event draws one. Both the fold budget and the layout start here.
    private static func collapsedSizes(for entries: [BannerQueue.Entry]) -> [CGSize] {
        entries.map { entry in
            BannerGeometry.cardSize(
                foldedCount: 0, expanded: false, maxRows: 0,
                actionCount: entry.event.pillActions.count
            )
        }
    }

    /// How many fold rows each card may draw. The screen decides — this is
    /// the whole of the "fill the screen" rule, and the only place that knows
    /// both the display and where each card sits on it. `BannerView` is handed
    /// the answer; it must not be able to ask.
    ///
    /// Bounded a second time by what the fold actually kept, so the card's
    /// height can never pay for a named row the view has no event for. The
    /// `+ 1` is the "and N earlier" line, which needs no event.
    private static func foldRows(for entries: [BannerQueue.Entry], on screen: ScreenDescriptor) -> [Int] {
        let collapsed = collapsedSizes(for: entries)
        return entries.indices.map { index in
            min(
                BannerGeometry.foldRowCapacity(
                    on: screen,
                    above: BannerGeometry.heightAbove(index: index, sizes: collapsed),
                    cardHeight: collapsed[index].height
                ),
                entries[index].folded.count + 1
            )
        }
    }

    private static func frames(
        for entries: [BannerQueue.Entry],
        rows: [Int],
        on screen: ScreenDescriptor
    ) -> [CGRect?] {
        BannerGeometry.stackFrames(
            on: screen,
            sizes: entries.indices.map { index in
                BannerGeometry.cardSize(
                    foldedCount: entries[index].coalescedCount,
                    expanded: entries[index].expanded,
                    maxRows: rows[index],
                    actionCount: entries[index].event.pillActions.count
                )
            }
        )
    }

    /// The screen is the whole of the cap now. A `min(capacity, 3)` used to
    /// sit here from the first feel-test; it made every display behave like
    /// a laptop with a window open, and burying banner four was the thing
    /// the overflow badge exists to *report*, not enforce.
    private func syncCapacity() {
        queue.setCapacity(targetScreen.map { BannerGeometry.capacity(on: $0) } ?? 0)
    }

    private func render(_ entries: [BannerQueue.Entry]) {
        guard let screen = targetScreen else {
            panels.values.forEach { $0.close() }
            panels.removeAll()
            overflowBadge?.close()
            overflowBadge = nil
            syncWatchPolling()
            return
        }

        // A card about to appear gets a reading taken now — the poll is 2s
        // and a banner must not out-run it onto a shared screen. Re-renders
        // of cards already up (hover, restack) use what the poll last saw,
        // which is what keeps a window-list call off the hover path.
        let shy = entries.contains { panels[$0.id] == nil }
            ? watch.refresh(notifying: false)
            : watch.isShy

        // Close panels whose entries left the visible set. `expire` moves an
        // ask into `parked` before notifying, so "is it on the ledge now"
        // distinguishes a park (drift toward the edge, where its fin is about
        // to emerge) from a dismissal (fade and rise, the arrival reversed).
        let liveIDs = Set(entries.map(\.id))
        for (id, panel) in panels where !liveIDs.contains(id) {
            let parked = queue.parked.contains { $0.id == id }
            panel.close(parked ? .parked : .dismissed)
            panels.removeValue(forKey: id)
        }

        // One layout pass for the whole stack: a hovered banner expands, and
        // every card under it has to move down by exactly that much.
        //
        // The fallback below protects the *hovered card's own* panel and
        // nothing else. Cards beneath it losing their slot is the intended
        // outcome, not a failure — that is how a fold gets to fill the screen
        // instead of stopping at whatever happened to arrive under it — and
        // they come straight back on unhover. It used to collapse the fold if
        // *any* card in the stack lost its frame, which meant a fold could
        // never grow past the cards below it however much room the display
        // had. Since `foldRowCapacity` now sizes the expansion to fit, this
        // should not fire at all; it stays because closing the panel under the
        // pointer would strand the hover (no exit event follows a panel that
        // is simply gone) and pause the queue for good, and refusing to grow
        // is the honest failure.
        var laidOut = entries
        var rows = Self.foldRows(for: laidOut, on: screen)
        var frames = Self.frames(for: laidOut, rows: rows, on: screen)
        if let grown = laidOut.firstIndex(where: \.expanded), frames[grown] == nil {
            laidOut[grown].expanded = false
            rows = Self.foldRows(for: laidOut, on: screen)
            frames = Self.frames(for: laidOut, rows: rows, on: screen)
        }

        for (index, entry) in laidOut.enumerated() {
            guard let frame = frames[index] else {
                // An expanded fold can push the tail of the stack off screen.
                // Drop those panels — the entries stay in the queue, and the
                // next render (unhover, dismissal) puts them back.
                panels.removeValue(forKey: entry.id)?.close(.dismissed)
                continue
            }
            let hover: (Bool) -> Void = { [weak self] hovering in
                self?.queue.setHover(hovering, id: entry.id)
            }
            let dismiss: () -> Void = { [weak self] in
                self?.queue.dismiss(id: entry.id)
            }
            let activate: () -> Void = { [weak self] in
                self?.actionRouter.performDefault(for: entry.event)
                self?.queue.dismiss(id: entry.id)
            }
            // A pill runs *its* action and takes the banner down, same as the
            // face: the card asked a question, and any pill answers it.
            let action: (NotificationEvent.Action) -> Void = { [weak self] chosen in
                self?.actionRouter.perform(chosen, for: entry.event)
                self?.queue.dismiss(id: entry.id)
            }
            // A row of an open fold runs *its* event's action and then takes
            // the whole banner down: you opened the thread to deal with it,
            // and you just did. Leaving the card up would put you back in
            // front of a list whose reason for existing you have answered.
            let activateFolded: (NotificationEvent) -> Void = { [weak self] folded in
                self?.actionRouter.performDefault(for: folded)
                self?.queue.dismiss(id: entry.id)
            }
            if let existing = panels[entry.id] {
                existing.update(
                    entry: entry, maxFoldRows: rows[index], shy: shy, frame: frame,
                    onHover: hover, onDismiss: dismiss,
                    onActivate: activate, onAction: action,
                    onActivateFolded: activateFolded
                )
            } else {
                panels[entry.id] = BannerPanelController(
                    entry: entry, maxFoldRows: rows[index], shy: shy, frame: frame,
                    onHover: hover, onDismiss: dismiss,
                    onActivate: activate, onAction: action,
                    onActivateFolded: activateFolded
                )
            }
        }

        renderOverflowBadge(under: frames, on: screen)
        syncWatchPolling()
    }

    /// Nobody to be shy in front of when the screen is empty: the poll runs
    /// only while trill has something drawn.
    private func syncWatchPolling() {
        watch.setPolling(!panels.isEmpty || !ledgePanels.isEmpty)
    }

    /// The ledge: one fin panel per parked ask, hugging the right screen
    /// edge. Same shape as `render` — close what left, create/update what
    /// stayed — and the same truth: `queue.parked` decides everything,
    /// including which single entry is slid out (`entry.expanded`).
    private var ledgePanels: [String: LedgePanelController] = [:]

    private func renderLedge(_ entries: [BannerQueue.Entry]) {
        guard let screen = targetScreen else {
            ledgePanels.values.forEach { $0.close() }
            ledgePanels.removeAll()
            syncWatchPolling()
            return
        }

        let shy = entries.contains { ledgePanels[$0.id] == nil }
            ? watch.refresh(notifying: false)
            : watch.isShy

        // Answered or evicted asks fade back into the edge they came from;
        // only losing the screen itself tears fins down without motion.
        let liveIDs = Set(entries.map(\.id))
        for (id, panel) in ledgePanels where !liveIDs.contains(id) {
            panel.close(animated: true)
            ledgePanels.removeValue(forKey: id)
        }

        let fins = BannerGeometry.Ledge.finFrames(on: screen, count: entries.count)
        for (index, entry) in entries.enumerated() {
            let frame: CGRect
            if entry.expanded {
                // The same arithmetic `BannerView` sizes itself with —
                // maxRows 0, matching the view's fold-less parked card.
                let cardSize = BannerGeometry.cardSize(
                    foldedCount: entry.coalescedCount,
                    expanded: entry.expanded,
                    maxRows: 0,
                    actionCount: entry.event.pillActions.count
                )
                frame = BannerGeometry.Ledge.cardFrame(
                    finFrame: fins[index], cardSize: cardSize, on: screen
                )
            } else {
                frame = fins[index]
            }

            let hover: (Bool) -> Void = { [weak self] hovering in
                self?.queue.setParkedHover(hovering, id: entry.id)
            }
            let dismiss: () -> Void = { [weak self] in
                self?.queue.dismiss(id: entry.id)
            }
            let activate: () -> Void = { [weak self] in
                self?.actionRouter.performDefault(for: entry.event)
                self?.queue.dismiss(id: entry.id)
            }
            // Any pill answers the parked question, same as on a banner.
            let action: (NotificationEvent.Action) -> Void = { [weak self] chosen in
                self?.actionRouter.perform(chosen, for: entry.event)
                self?.queue.dismiss(id: entry.id)
            }
            if let existing = ledgePanels[entry.id] {
                existing.update(
                    entry: entry, shy: shy, frame: frame,
                    onHover: hover, onDismiss: dismiss,
                    onActivate: activate, onAction: action
                )
            } else {
                ledgePanels[entry.id] = LedgePanelController(
                    entry: entry, shy: shy, frame: frame,
                    onHover: hover, onDismiss: dismiss,
                    onActivate: activate, onAction: action
                )
            }
        }
        syncWatchPolling()
    }

    /// The queue can hold more than the display fits, and until now that was
    /// invisible — events looked late rather than waiting. When anything is
    /// waiting, a small "⌄ N waiting" tag hangs off the bottom card's
    /// trailing corner. It is a *report*, not a control: no click, no hover,
    /// and it disappears the moment the line drains.
    private var overflowBadge: OverflowBadgeController?

    private func renderOverflowBadge(under frames: [CGRect?], on screen: ScreenDescriptor) {
        let waiting = queue.waitingCount
        guard waiting > 0, let last = frames.compactMap({ $0 }).last else {
            overflowBadge?.close()
            overflowBadge = nil
            return
        }
        if let overflowBadge {
            overflowBadge.update(count: waiting, under: last)
        } else {
            overflowBadge = OverflowBadgeController(count: waiting, under: last)
        }
    }
}
