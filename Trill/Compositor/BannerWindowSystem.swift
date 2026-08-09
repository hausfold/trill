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
    private var panels: [String: BannerPanelController] = [:]
    private var screenObserver: NSObjectProtocol?

    init(queue: BannerQueue, actionRouter: ActionRouter) {
        self.queue = queue
        self.actionRouter = actionRouter
        queue.onVisibleChanged = { [weak self] entries in
            self?.render(entries)
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
                self.syncCapacity()
                self.render(self.queue.visible)
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
        queue.onVisibleChanged = nil
    }

    /// Banners live on the screen with the menu bar (`NSScreen.screens
    /// .first`), matching where the system draws its own. Per-display
    /// routing is a planned extension — the queue/panel split already
    /// supports it.
    private var targetScreen: ScreenDescriptor? {
        NSScreen.screens.first.map(ScreenDescriptor.init(screen:))
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
        entries.indices.map { index in
            min(
                BannerGeometry.foldRowCapacity(on: screen, index: index),
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
                    maxRows: rows[index]
                )
            }
        )
    }

    private func syncCapacity() {
        let capacity = targetScreen.map { BannerGeometry.capacity(on: $0) } ?? 0
        queue.setCapacity(min(capacity, 3))
    }

    private func render(_ entries: [BannerQueue.Entry]) {
        guard let screen = targetScreen else {
            panels.values.forEach { $0.close() }
            panels.removeAll()
            return
        }

        // Close panels whose entries left the visible set.
        let liveIDs = Set(entries.map(\.id))
        for (id, panel) in panels where !liveIDs.contains(id) {
            panel.close()
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
                panels.removeValue(forKey: entry.id)?.close()
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
                    entry: entry, maxFoldRows: rows[index], frame: frame,
                    onHover: hover, onDismiss: dismiss,
                    onActivate: activate, onActivateFolded: activateFolded
                )
            } else {
                panels[entry.id] = BannerPanelController(
                    entry: entry, maxFoldRows: rows[index], frame: frame,
                    onHover: hover, onDismiss: dismiss,
                    onActivate: activate, onActivateFolded: activateFolded
                )
            }
        }
    }
}

extension ScreenDescriptor {
    @MainActor
    init(screen: NSScreen) {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        self.init(
            id: (number as? NSNumber)?.stringValue ?? screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame
        )
    }
}
