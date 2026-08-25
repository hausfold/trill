import Foundation

/// The other half of `trill ask`: which caller is still on the wire, blocked,
/// waiting to be told which pill the user pressed.
///
/// `trill send` is a one-way street — the daemon takes the event and the
/// caller exits. An ask is a round trip that outlives its request: the reply
/// is written when a pill is pressed, possibly minutes later, from the main
/// actor, into a socket the socket queue is still holding open. This is the
/// only object that knows both ends, so it owns the rule that makes the whole
/// thing safe: **an ask resolves exactly once, and the first resolution
/// wins.** Both paths that end one routinely fire in the same turn — a pill
/// click answers the question and then takes the banner down, and a takedown
/// is itself an abandonment — so the loser has to be a silent no-op and not a
/// second line written down a socket the first reply already finished.
///
/// It is deliberately a lock and a dictionary rather than an actor: the
/// answer path runs on the main actor and must not reorder against the
/// takedown that follows it two lines later. `await` would make that ordering
/// a coin flip.
final class AskBroker: @unchecked Sendable {
    /// How an ask ended. Only `answered` carries a choice; every other
    /// outcome is the CLI's "nobody said" exit, and the *reason* is the
    /// difference between a user who declined to answer and a machine that
    /// never asked.
    enum Outcome: String, Sendable, Codable {
        /// A pill was pressed.
        case answered
        /// `--timeout` ran out with the question still on screen.
        case timeout
        /// The user took the banner down without answering — the ✕, or a
        /// newer ask pushing this one off the ledge.
        case dismissed
        /// The asker hung up: Ctrl-C, or its terminal went away.
        case canceled
        /// The question never reached a screen — a rule dropped it, quiet
        /// hours demoted it to the inbox. Reported immediately rather than
        /// waited out: nothing is going to answer a banner nobody drew.
        case dropped
    }

    struct Answer: Sendable {
        var outcome: Outcome
        /// Index of the pill pressed, `nil` for every other outcome.
        var choice: Int?
        /// That pill's label, for a caller that would rather read than count.
        var label: String?
    }

    /// How long an ask may go unclaimed by the compositor before the broker
    /// gives up on it. Registering happens on the socket queue and claiming a
    /// couple of hops later on the main actor — microseconds — so anything
    /// past this means the event is not coming: the repository deduped it, or
    /// it was dropped before anyone could decide anything. Blocking a caller
    /// for its full `--timeout` on a banner that will never be drawn is the
    /// hang this exists to prevent.
    static let defaultClaimGrace: TimeInterval = 3

    private struct Pending {
        let peer: UInt64
        let labels: [String]
        let resolve: @Sendable (Answer) -> Void
        var claimed: Bool
    }

    /// Take a banner down whose question has stopped mattering — the asker
    /// hung up, or its clock ran out. Injected rather than assigned, so it is
    /// immutable across the threads that read it. Hops to the main actor on
    /// the far side; the broker itself belongs to no actor.
    private let retract: @Sendable (String) -> Void
    private let claimGrace: TimeInterval
    private let lock = NSLock()
    private let timers = DispatchQueue(label: "com.hausfold.trill.ask")
    private var pending: [String: Pending] = [:]

    init(
        claimGrace: TimeInterval = AskBroker.defaultClaimGrace,
        retract: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.claimGrace = claimGrace
        self.retract = retract
    }

    /// A caller is now blocked on `id`. `resolve` is called exactly once,
    /// on whichever thread ends the ask.
    func register(
        id: String,
        peer: UInt64,
        labels: [String],
        timeout: TimeInterval?,
        resolve: @escaping @Sendable (Answer) -> Void
    ) {
        lock.lock()
        pending[id] = Pending(peer: peer, labels: labels, resolve: resolve, claimed: false)
        lock.unlock()

        timers.asyncAfter(deadline: .now() + claimGrace) { [weak self] in
            self?.expireUnclaimed(id)
        }
        if let timeout, timeout > 0 {
            timers.asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(id, outcome: .timeout, choice: nil, retract: true)
            }
        }
    }

    /// The compositor has the ask — a banner is on screen (or on the ledge)
    /// for it, so the claim watchdog can stand down and the question can now
    /// take as long as the user does.
    func claim(id: String) {
        lock.lock()
        pending[id]?.claimed = true
        lock.unlock()
    }

    /// A pill was pressed. False when nothing was waiting — an ask that
    /// already timed out, or a hand-authored `reply` action with no asker
    /// behind it — and false for a choice this ask never offered, so a
    /// malformed index can never become an exit code.
    @discardableResult
    func answer(id: String, choice: Int) -> Bool {
        lock.lock()
        let offered = pending[id]?.labels.indices.contains(choice) ?? false
        lock.unlock()
        guard offered else { return false }
        return finish(id, outcome: .answered, choice: choice, retract: false)
    }

    /// The banner is gone and nobody answered.
    @discardableResult
    func abandon(id: String) -> Bool {
        finish(id, outcome: .dismissed, choice: nil, retract: false)
    }

    /// The pipeline decided this event is not going on screen at all.
    @discardableResult
    func unshown(id: String) -> Bool {
        finish(id, outcome: .dropped, choice: nil, retract: false)
    }

    /// A connection went away: everything it was waiting on ends, and the
    /// banners it put up come down. A question whose asker is gone is worse
    /// than no question — pressing Allow on it would answer nothing.
    func cancel(peer: UInt64) {
        lock.lock()
        let ids = pending.compactMap { $0.value.peer == peer ? $0.key : nil }
        lock.unlock()
        for id in ids {
            finish(id, outcome: .canceled, choice: nil, retract: true)
        }
    }

    /// Is anyone still blocked on this event? Only for logging and tests —
    /// never branch a reply on it, because it can change between the ask and
    /// the answer.
    func isPending(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending[id] != nil
    }

    private func expireUnclaimed(_ id: String) {
        lock.lock()
        let unclaimed = pending[id].map { !$0.claimed } ?? false
        lock.unlock()
        guard unclaimed else { return }
        finish(id, outcome: .dropped, choice: nil, retract: false)
    }

    @discardableResult
    private func finish(_ id: String, outcome: Outcome, choice: Int?, retract: Bool) -> Bool {
        lock.lock()
        let entry = pending.removeValue(forKey: id)
        lock.unlock()
        guard let entry else { return false }

        let answered = outcome == .answered
        let choice = answered ? choice : nil
        let label = choice.flatMap { entry.labels.indices.contains($0) ? entry.labels[$0] : nil }
        entry.resolve(Answer(outcome: outcome, choice: choice, label: label))
        if retract { self.retract(id) }
        return true
    }
}
