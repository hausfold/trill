import Foundation

/// Main-actor banner scheduling: what is visible, what waits, what coalesces.
/// The queue owns event state so panels stay disposable — a display topology
/// rebuild throws every panel away and redraws from here, losing nothing.
@MainActor
final class BannerQueue {
    struct Entry: Identifiable, Equatable {
        /// How many folded thread-mates the expanded list keeps around. The
        /// number of rows actually drawn is set by the *screen*
        /// (`BannerGeometry.foldRowCapacity`), and this sits above the row
        /// capacity of any display trill can size a card for — roughly 86 rows
        /// on a 6K XDR — so it is a memory backstop, not the thing you feel.
        /// It used to be 8, which silently was the cap: a ten-message thread
        /// could not list ten however tall the screen was. The *count* of
        /// folded events is tracked separately, so trimming this list never
        /// makes the banner under-report a burst.
        static let foldPreviewLimit = 96

        /// The face of the banner: the newest event in the fold.
        var event: NotificationEvent
        /// Thread-mates folded in behind the face, newest first — the face
        /// event is not among them, and the tail beyond `foldPreviewLimit`
        /// is dropped (it survives in the inbox; this is a glance).
        var folded: [NotificationEvent] = []
        /// Everything behind the face, including what `folded` dropped.
        var coalescedCount: Int = 0
        /// Set by the queue while the pointer is over this banner and there
        /// is something behind the face worth showing. Presentation state,
        /// but it belongs here and not in the panel: expanding one card
        /// re-lays every card under it, so the render pass has to see it.
        var expanded: Bool = false
        /// Stable for the life of the fold. Panels and dismiss timers key off
        /// it, so swapping the face event must never change it.
        let id: String

        init(event: NotificationEvent) {
            self.event = event
            self.id = event.id
        }

        /// Fold a newer thread-mate in: it takes the face, the outgoing face
        /// drops to the head of the list behind it.
        mutating func fold(_ latest: NotificationEvent) {
            folded.insert(event, at: 0)
            if folded.count > Self.foldPreviewLimit { folded.removeLast() }
            coalescedCount += 1
            event = latest
        }
    }

    /// Redraw callback; the window system owns the panels.
    var onVisibleChanged: (([Entry]) -> Void)?

    private(set) var visible: [Entry] = []
    private var waiting: [Entry] = []
    private var capacity: Int
    /// Which banner the pointer is over, if any. Hover both pauses the queue
    /// and expands that one banner's fold, so it has to be an id, not a bool.
    private var hoveredID: String?
    private var paused: Bool { hoveredID != nil }
    private var dismissTimers: [String: Task<Void, Never>] = [:]

    private let displayDuration: Duration
    /// Thread-mates arriving within this window fold into the existing
    /// banner instead of stacking a new one.
    private let coalesceWindow: TimeInterval
    private var lastThreadArrival: [String: (id: String, at: Date)] = [:]

    init(capacity: Int = 3, displayDuration: Duration = .seconds(6), coalesceWindow: TimeInterval = 10) {
        self.capacity = max(0, capacity)
        self.displayDuration = displayDuration
        self.coalesceWindow = coalesceWindow
    }

    // MARK: - Intake

    func enqueue(_ event: NotificationEvent, now: Date = .now) {
        if let thread = event.thread,
           let last = lastThreadArrival[thread],
           now.timeIntervalSince(last.at) < coalesceWindow,
           coalesce(into: last.id, latest: event) {
            lastThreadArrival[thread] = (last.id, now)
            return
        }

        if let thread = event.thread {
            lastThreadArrival[thread] = (event.id, now)
        }

        let entry = Entry(event: event)
        if visible.count < capacity && !paused {
            show(entry)
        } else {
            waiting.append(entry)
        }
        notify()
    }

    /// Fold `latest` into an existing banner/queued entry for its thread.
    /// The newest content wins the face of the banner; the events behind it
    /// are kept, not just counted — hovering the banner lists them.
    private func coalesce(into id: String, latest: NotificationEvent) -> Bool {
        if let i = visible.firstIndex(where: { $0.id == id }) {
            visible[i].fold(latest)
            refreshExpansion()
            armDismiss(for: id) // fresh content, fresh clock
            notify()
            return true
        }
        if let i = waiting.firstIndex(where: { $0.id == id }) {
            waiting[i].fold(latest)
            return true
        }
        return false
    }

    // MARK: - Lifecycle

    func dismiss(id: String) {
        dismissTimers.removeValue(forKey: id)?.cancel()
        visible.removeAll { $0.id == id }
        if hoveredID == id {
            // The pointer's target just vanished. SwiftUI does not reliably
            // send the matching exit for a view that goes away under the
            // cursor, and a hover left set would pause the queue forever.
            hoveredID = nil
            visible.forEach { armDismiss(for: $0.id) }
        }
        refill()
        notify()
    }

    func dismissAll() {
        dismissTimers.values.forEach { $0.cancel() }
        dismissTimers.removeAll()
        hoveredID = nil
        visible.removeAll()
        waiting.removeAll()
        notify()
    }

    /// Hover: while the pointer is over a banner, nothing auto-dismisses and
    /// nothing new rotates in under the cursor — and that one banner expands
    /// its fold. Exit only clears the hover it owns, because entering B can
    /// beat leaving A.
    func setHover(_ hovering: Bool, id: String) {
        if hovering {
            guard hoveredID != id else { return }
            hoveredID = id
            dismissTimers.values.forEach { $0.cancel() }
            dismissTimers.removeAll()
        } else {
            guard hoveredID == id else { return }
            hoveredID = nil
            visible.forEach { armDismiss(for: $0.id) }
            refill()
        }
        refreshExpansion()
        notify()
    }

    /// Display capacity changed (topology rebuild, smaller screen). Overflow
    /// slides back into the waiting line — events survive every rebuild.
    func setCapacity(_ newCapacity: Int) {
        capacity = max(0, newCapacity)
        while visible.count > capacity {
            let overflow = visible.removeLast()
            dismissTimers.removeValue(forKey: overflow.id)?.cancel()
            waiting.insert(overflow, at: 0)
            if hoveredID == overflow.id {
                // The card under the pointer just left the screen with the
                // display it was on. No exit event is coming for a panel
                // torn down by a topology rebuild, and a hover left set
                // would pause the queue for good.
                hoveredID = nil
            }
        }
        if !paused {
            visible.forEach { armDismiss(for: $0.id) }
        }
        refill()
        notify()
    }

    // MARK: - Internals

    private func show(_ entry: Entry) {
        visible.append(entry)
        armDismiss(for: entry.id)
    }

    private func refill() {
        while !paused, visible.count < capacity, !waiting.isEmpty {
            show(waiting.removeFirst())
        }
    }

    /// A banner is expanded when it is hovered *and* has something folded
    /// behind its face — a lone banner has nothing to show, so it stays the
    /// height it arrived at.
    private func refreshExpansion() {
        for i in visible.indices {
            visible[i].expanded = visible[i].id == hoveredID && visible[i].coalescedCount > 0
        }
    }

    private func armDismiss(for id: String) {
        dismissTimers[id]?.cancel()
        guard !paused else { return }
        dismissTimers[id] = Task { [weak self, displayDuration] in
            try? await Task.sleep(for: displayDuration)
            guard !Task.isCancelled else { return }
            self?.dismiss(id: id)
        }
    }

    private func notify() {
        onVisibleChanged?(visible)
    }
}
