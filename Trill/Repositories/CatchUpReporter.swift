import Foundation
import os.log

/// The consumer that turns "you're back" into one card.
///
/// It sits where `DigestScheduler` sits — beside the compositor, never in
/// front of it — and it is the same shape for the same reason: nothing here
/// can stall the pipeline, and a card that never gets drawn costs a glance,
/// not an event. The difference is what triggers it. A digest flushes on
/// trill's clock; this fires on **the user's return**, which is the one
/// moment an interruption is not an interruption: they just sat down and are
/// looking at the screen.
///
/// Which is also why it does **not** hold for quiet hours. A 3am digest card
/// is trill talking to an empty chair; a 3am catch-up card is trill answering
/// the person who just unlocked the Mac. Quiet hours exist to stop the first,
/// and applying them here would mean the one card you asked for by unlocking
/// is the one card you don't get.
@MainActor
final class CatchUpReporter {
    /// Where the card goes. The composition root points it at the banner
    /// queue; a test points it at an array.
    var onCard: ((NotificationEvent) -> Void)?

    /// Where history is. A closure and not a handle, because it is asked at
    /// return time: history can be switched off (or back on) between one
    /// absence and the next, and a captured handle would count rows the user
    /// stopped keeping. No database is not a failure here — it is the whole
    /// answer: nothing is being kept, so nothing can have been missed.
    ///
    /// Set by the composition root, like `onCard`, because both of them point
    /// back at objects that don't exist yet when this one is built.
    var database: () -> AppDatabase? = { nil }

    /// Read live, like every other switch: turning the card off in Settings
    /// (or by typing it into config.json) applies to the next unlock, not the
    /// next launch.
    private let enabled: () -> Bool

    private static let log = Logger(subsystem: "com.hausfold.trill", category: "catch-up")

    init(enabled: @escaping () -> Bool) {
        self.enabled = enabled
    }

    /// An absence ended. Count what landed in it and draw the card, if there
    /// is one worth drawing.
    ///
    /// Every way of declining is silent and none of them is an error: the
    /// switch is off, the absence was a coffee break, history is off, or —
    /// the good case — nothing happened while you were gone.
    func report(returned window: ClosedRange<Date>, now: Date = .now) {
        guard enabled() else { return }
        guard let counted = CatchUpCard.window(from: window.lowerBound, to: window.upperBound)
        else { return }
        guard let database = database() else { return }

        let tally = CatchUpTally(
            since: counted.lowerBound,
            span: counted.upperBound.timeIntervalSince(counted.lowerBound),
            counts: database.missedCounts(since: counted.lowerBound)
        )
        guard let card = CatchUpCard.card(for: tally, now: now) else {
            Self.log.debug("nothing landed while away")
            return
        }
        // Counts and kinds, no content — the same bar every other log in this
        // app is held to.
        Self.log.info("catch-up card: \(tally.total, privacy: .public) missed")
        onCard?(card)
    }
}
