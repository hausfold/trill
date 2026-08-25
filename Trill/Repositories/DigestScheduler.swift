import Foundation
import os.log

/// The consumer that makes `delivery: digest` mean something.
///
/// It sits beside the compositor on the repository's delivery stream, tallies
/// everything a rule batched, and on the hour hands one card per digest name
/// to whoever is drawing. It is a *consumer* and not a stage: nothing here can
/// stall the pipeline, and a digest that never flushes costs an inbox row, not
/// a lost event.
///
/// Quiet hours hold a flush rather than skipping it. A 3am card would be the
/// one interruption the whole feature exists to prevent, and dropping the
/// tally would silently lose the count — so the tally stays pending and the
/// first flush after the window ends says "23 quiet things" instead of nine.
@MainActor
final class DigestScheduler {
    /// Longest the ticker sleeps in one go. The deadline is wall-clock, so a
    /// Mac that slept through the top of the hour has to notice on the way
    /// back rather than on the *next* hour — this bounds how late that is.
    static let maxSleep: TimeInterval = 600

    /// Where a flushed card goes. The composition root points it at the
    /// banner queue; a test points it at an array.
    var onCard: ((NotificationEvent) -> Void)?

    private var tallies: [String: DigestTally] = [:]
    private var ticker: Task<Void, Never>?
    /// Read live, like every other rules question: quiet hours edited into
    /// `rules.json` apply to the next flush, not the next launch.
    private let quietHours: () -> RuleSet.QuietHours?

    private static let log = Logger(subsystem: "com.hausfold.trill", category: "digest")

    init(quietHours: @escaping () -> RuleSet.QuietHours? = { nil }) {
        self.quietHours = quietHours
    }

    // MARK: - Intake

    /// Count one event into its digest. `now` opens the window for a digest
    /// that had none; the tally then tracks the earliest event timestamp it
    /// has seen, which is what the inbox scopes to.
    func accumulate(_ event: NotificationEvent, digest name: String, now: Date = .now) {
        tallies[name, default: DigestTally(since: now)].add(event)
    }

    /// What is waiting, by digest name — the queue's `visible` for this
    /// surface. Read by tests; the app only ever flushes.
    var pending: [String: DigestTally] { tallies }

    // MARK: - Flush

    /// Build the cards due now and clear what they counted. Returns empty
    /// during quiet hours (holding every tally) and when nothing is pending.
    ///
    /// Injectable clock, no I/O: this is the whole behavior of the feature
    /// and it is testable without a timer.
    func flush(now: Date, calendar: Calendar = .current) -> [NotificationEvent] {
        guard !tallies.isEmpty else { return [] }
        if quietHours()?.contains(now, calendar: calendar) == true {
            Self.log.debug("digest flush held: quiet hours")
            return []
        }
        // Name order, so two digests flushing on the same tick stack in a
        // stable order rather than whatever the dictionary felt like.
        let cards = tallies.keys.sorted().map { name in
            DigestCard.event(name: name, tally: tallies[name]!, now: now)
        }
        tallies.removeAll()
        return cards
    }

    // MARK: - Lifecycle

    func start() {
        guard ticker == nil else { return }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date.now
                let deadline = DigestSchedule.nextFlush(after: now)
                let interval = min(deadline.timeIntervalSince(now), Self.maxSleep)
                // Never zero: a clock that jumped backwards past the deadline
                // must not turn this into a spin.
                try? await Task.sleep(for: .seconds(max(interval, 1)))
                guard !Task.isCancelled else { return }
                // Woke on the clamp rather than on the hour: keep waiting.
                guard Date.now >= deadline else { continue }
                self?.deliverDueCards()
            }
        }
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
    }

    private func deliverDueCards() {
        let cards = flush(now: .now)
        guard !cards.isEmpty else { return }
        // Ids and counts only — a digest card's body names sources, which is
        // as far as this may go.
        Self.log.info("flushed \(cards.count, privacy: .public) digest card(s)")
        for card in cards { onCard?(card) }
    }
}
