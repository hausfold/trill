import Foundation

/// Main-actor banner scheduling: what is visible, what waits, what coalesces
/// — and what parks. The queue owns event state so panels stay disposable —
/// a display topology rebuild throws every panel away and redraws from here,
/// losing nothing.
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

    /// Fins the ledge holds at most. Past this the *oldest* ask yields —
    /// the ledge is a glanceable strip, not a second queue, and everything
    /// it evicts already survives in the inbox like every delivered event.
    static let parkedCapacity = 5

    /// How long a parked ask may survive daemon restarts. A question still
    /// on the edge of the screen a week after it was asked has outlived its
    /// subject; keeping it there teaches you to stop looking at the ledge,
    /// which costs more than the one ask it loses (it stays in the inbox).
    static let parkedLifetime: TimeInterval = 7 * 24 * 3600

    /// Redraw callback; the window system owns the panels.
    var onVisibleChanged: (([Entry]) -> Void)?
    /// Ledge redraw callback — the parked bucket changed. Separate from
    /// `onVisibleChanged` because the two surfaces re-render independently:
    /// a fin appearing must not restack the banner column and vice versa.
    var onParkedChanged: (([Entry]) -> Void)?
    /// The same change, for everything that isn't the compositor: the ledge
    /// store (which mirrors the bucket to disk so fins survive a relaunch)
    /// and the resolution monitor (which arms a poller per parked ask and
    /// disarms it the moment the fin goes). A second property rather than a
    /// list of observers because there is exactly one of each and their
    /// lifetimes differ — the compositor's callback is torn down with the
    /// window system, these outlive it.
    var onParkedForResolution: (([Entry]) -> Void)?

    private(set) var visible: [Entry] = []
    /// Held back until a slot frees. Kept ordered by urgency (critical
    /// first), arrival order within a rank — a burst of chatter can delay a
    /// critical's *slot*, never bury it behind twenty notes.
    private var waiting: [Entry] = []
    /// The ledge: asks whose dismiss clock ran out with nobody there,
    /// oldest first. They render as fins on the screen edge, not banners,
    /// and they have no clock — a question stays asked until it's answered,
    /// dismissed, or evicted by a newer ask past `parkedCapacity`.
    private(set) var parked: [Entry] = []
    /// Which parked entry the pointer is over — that one slides out as a
    /// full card. An id for the same reason `hoveredID` is: entering fin B
    /// can beat leaving fin A. Independent of the stack's hover; the two
    /// surfaces share no clock.
    private var parkedHoverID: String?
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
        // A re-sent ask supersedes its own fin. Without this, a lane that
        // says "still blocked" every ten minutes grows a column of fins for
        // one question — and the ledge holds five, so three such lanes would
        // evict everything else. Only the *parked* copy yields: a visible
        // banner and a fresh arrival are two arrivals, which is what the
        // coalesce window is for.
        if let key = event.key, let index = parked.firstIndex(where: { $0.event.key == key }) {
            let superseded = parked.remove(at: index)
            if parkedHoverID == superseded.id { parkedHoverID = nil }
            notifyParked()
        }

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
        // Hover does NOT gate arrivals: a new card appends at the bottom of
        // the stack, so nothing moves under the cursor — and its dismiss
        // timer stays unarmed while the queue is paused (`armDismiss`), so
        // it waits with everything else. It used to be held in `waiting`,
        // which read as "I sent five and three showed" whenever the pointer
        // happened to rest on the stack. Only a *freed slot* refilling is
        // still deferred to unhover: a refill can follow a dismissal above
        // the cursor, and that does shift cards.
        if visible.count < capacity {
            show(entry)
        } else {
            // After every waiting entry of equal-or-higher urgency: a new
            // arrival never queue-jumps its own rank.
            let index = waiting.firstIndex { $0.event.urgency < event.urgency }
                ?? waiting.endIndex
            waiting.insert(entry, at: index)
        }
        notify()
    }

    /// How many entries the display doesn't have room for right now — what
    /// the compositor's overflow badge counts.
    var waitingCount: Int { waiting.count }

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
        if parked.contains(where: { $0.id == id }) {
            parked.removeAll { $0.id == id }
            if parkedHoverID == id { parkedHoverID = nil }
            notifyParked()
            return
        }
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
        guard !parked.isEmpty else { return }
        parked.removeAll()
        parkedHoverID = nil
        notifyParked()
    }

    /// A question got answered somewhere else — `trill resolve`, a webhook
    /// that carried `resolves`, or a poller that finally saw what it was
    /// waiting for. Clears every entry answering to one of these names,
    /// wherever it sits, and reports how many went so the caller can say
    /// what it did.
    ///
    /// Deliberately one-way: nothing here can *un*-resolve. A check that
    /// flips back to "not done" must not conjure a fin the user already
    /// watched leave — the event is in the inbox, and a screen that
    /// re-opens questions behind your back stops being one you can trust.
    @discardableResult
    func resolve(keys: [String]) -> Int {
        let names = Set(keys)
        guard !names.isEmpty else { return 0 }
        func answers(_ entry: Entry) -> Bool {
            !entry.event.resolutionNames.isDisjoint(with: names)
        }

        let waitingBefore = waiting.count
        waiting.removeAll(where: answers)
        var cleared = waitingBefore - waiting.count

        // Through `dismiss`, one at a time: it owns the timer teardown, the
        // stranded-hover rule and the refill, and resolving a banner is a
        // dismissal in every respect except who did it.
        for id in visible.filter(answers).map(\.id) + parked.filter(answers).map(\.id) {
            dismiss(id: id)
            cleared += 1
        }
        // A waiting entry leaving changes the overflow badge's count and
        // nothing else on screen, so it needs its own redraw.
        if waitingBefore != waiting.count { notify() }
        return cleared
    }

    /// The dismiss clock ran out with nobody there. Most kinds are simply
    /// done (they survive in the inbox); an `ask` is a question nobody has
    /// answered yet, and quietly dropping the one event that is *blocked on
    /// the user* is the failure the ledge exists to end — it parks instead.
    func expire(id: String) {
        guard let index = visible.firstIndex(where: { $0.id == id }),
              visible[index].event.kind == .ask
        else {
            dismiss(id: id)
            return
        }
        dismissTimers.removeValue(forKey: id)?.cancel()
        var entry = visible.remove(at: index)
        entry.expanded = false
        if hoveredID == id {
            // Same stranded-hover rule as `dismiss`: no exit event follows
            // a panel that is simply gone.
            hoveredID = nil
            visible.forEach { armDismiss(for: $0.id) }
        }
        parked.append(entry)
        while parked.count > Self.parkedCapacity {
            let evicted = parked.removeFirst()
            if parkedHoverID == evicted.id { parkedHoverID = nil }
        }
        refill()
        notify()
        notifyParked()
    }

    /// Put fins back after a relaunch. The ledge is the one surface whose
    /// emptiness lies: a banner that vanished when the daemon restarted was
    /// already gone from the user's attention, but a *question* that vanished
    /// is one nobody will answer, silently — and an ask that can evaporate on
    /// a crash is exactly the failure the ledge was built to end.
    ///
    /// Restored entries arrive collapsed and unhovered whatever they were
    /// doing when the daemon went down, and never displace something the
    /// running session already parked — this runs at launch, so in practice
    /// there is nothing to displace, and if there is, live beats remembered.
    func restoreParked(_ restored: [(event: NotificationEvent, coalescedCount: Int)]) {
        guard !restored.isEmpty else { return }
        let known = Set(parked.map(\.id))
        for item in restored where !known.contains(item.event.id) {
            var entry = Entry(event: item.event)
            entry.coalescedCount = item.coalescedCount
            parked.append(entry)
        }
        while parked.count > Self.parkedCapacity {
            let evicted = parked.removeFirst()
            if parkedHoverID == evicted.id { parkedHoverID = nil }
        }
        notifyParked()
    }

    /// Hover over a fin (or the card it slid out): that one parked entry
    /// expands and the ledge re-renders. Exit only clears the hover it
    /// owns — entering fin B can beat leaving fin A, same as the stack.
    func setParkedHover(_ hovering: Bool, id: String) {
        if hovering {
            guard parkedHoverID != id else { return }
            parkedHoverID = id
        } else {
            guard parkedHoverID == id else { return }
            parkedHoverID = nil
        }
        for i in parked.indices {
            parked[i].expanded = parked[i].id == parkedHoverID
        }
        notifyParked()
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
            // Ahead of its own rank, not just at the front: it was already
            // on screen, so it refills before anything that never was —
            // without letting a demoted note cut in front of a critical.
            let index = waiting.firstIndex { $0.event.urgency <= overflow.event.urgency }
                ?? waiting.endIndex
            waiting.insert(overflow, at: index)
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
            // Expire, not dismiss: only the clock parks an ask. A user's
            // own dismissal (the ✕, a pill, the face) means they saw it,
            // and answered questions don't belong on the ledge.
            self?.expire(id: id)
        }
    }

    private func notify() {
        onVisibleChanged?(visible)
    }

    private func notifyParked() {
        onParkedChanged?(parked)
        onParkedForResolution?(parked)
    }
}
