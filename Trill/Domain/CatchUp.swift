import Foundation

/// What landed while nobody was here, counted by kind.
///
/// A **tally**, like the digest's — and for a stronger reason. The digest
/// batches what a rule asked to be held; this counts everything an absence
/// swallowed, which on a machine with agents on it is the whole night's
/// traffic. The card is the morning paper, not a replay of the stack: it is
/// a sentence with three numbers in it, and the rows behind it are already
/// in the inbox, one click away.
///
/// Counted **by kind**, not by source, because that is the axis you triage
/// on when you sit back down: two asks are two things blocking somebody, and
/// fourteen notes are fourteen things you can read later — however many
/// sources they came from.
struct CatchUpTally: Equatable, Sendable {
    /// The instant the absence began — what the card's inbox click scopes to.
    let since: Date
    /// How long the counted window is. Not how long you were gone: the
    /// window is clamped (see `CatchUpCard.maxLookback`), and a subtitle
    /// that claimed five days over one day of counts would be a lie.
    let span: TimeInterval
    private(set) var counts: [NotificationEvent.Kind: Int]

    init(since: Date, span: TimeInterval, counts: [NotificationEvent.Kind: Int] = [:]) {
        self.since = since
        self.span = span
        self.counts = counts.filter { $0.value > 0 }
    }

    var total: Int { counts.values.reduce(0, +) }

    var isEmpty: Bool { counts.isEmpty }

    /// Kinds in `Kind.allCases` order — ask, fault, chat, pulse, done, note —
    /// with the empty ones dropped.
    ///
    /// Declaration order, deliberately, and **not** biggest-first the way the
    /// digest ranks its sources. A digest card answers "what was all that
    /// noise", so the loudest source is the answer; this one answers "what do
    /// I have to deal with", and one ask outranks fourteen notes however the
    /// arithmetic falls.
    var ranked: [(kind: NotificationEvent.Kind, count: Int)] {
        NotificationEvent.Kind.allCases.compactMap { kind in
            counts[kind].map { (kind: kind, count: $0) }
        }
    }
}

/// The one card an unlock puts on screen.
///
/// Pure, and — like `DigestCard` — deliberately not a provider: the card is
/// composed by trill out of rows it already has, so it goes straight to the
/// `BannerQueue` and never re-enters the repository. Re-entering would policy
/// it (a rule matching `source: trill` could digest the catch-up card),
/// persist it, and leave a row in the very history it is a summary of.
enum CatchUpCard {
    /// Shortest absence worth reporting. Below this you went to make coffee,
    /// and a card about it is the interruption this feature exists to spare
    /// you.
    static let minimumAway: TimeInterval = 5 * 60

    /// How far back a card ever counts, however long the absence was.
    ///
    /// A week away is not a bigger paper, it is an archive — and the inbox is
    /// the archive. Capping here also caps the sentence: the numbers on this
    /// card stay numbers you can read at a glance instead of a wall you
    /// dismiss without reading, which is the only failure mode that would
    /// make the whole feature worthless.
    static let maxLookback: TimeInterval = 24 * 3600

    /// One fin's worth of thread key: a second card supersedes the first
    /// rather than stacking two summaries of overlapping windows.
    static let thread = "trill.catchup"

    /// The window a card would cover, or nil when the absence is too short to
    /// be worth one. Clamped to `maxLookback`, so the returned range is
    /// exactly what the counts will be over.
    static func window(from left: Date, to returned: Date) -> ClosedRange<Date>? {
        guard returned.timeIntervalSince(left) >= minimumAway else { return nil }
        let floor = returned.addingTimeInterval(-maxLookback)
        return max(left, floor)...returned
    }

    /// The card, or nil when nothing landed. Silence is the right output for
    /// a quiet night: an unlock that always produces a card is an unlock you
    /// learn to dismiss without reading.
    static func card(for tally: CatchUpTally, now: Date = .now) -> NotificationEvent? {
        guard !tally.isEmpty else { return nil }
        return NotificationEvent(
            // Deterministic in `now`, like the digest's: a test can predict
            // it, and two cards on the same tick can't collide.
            id: "catchup:\(Int(now.timeIntervalSince1970))",
            source: "trill",
            timestamp: now,
            title: "While you were away",
            subtitle: span(tally.span),
            body: breakdown(tally),
            symbol: "newspaper",
            thread: thread,
            kind: .note,
            // Low, always. Whatever is in the tally, the tally itself is not
            // urgent — the asks it counts are still on the ledge and the
            // faults are still in the inbox. This card is a pointer.
            urgency: .low,
            actions: [
                .init(
                    id: "inbox",
                    label: "Open inbox",
                    kind: .openInbox,
                    target: InboxScope.since(tally.since).actionTarget
                )
            ]
        )
    }

    /// "2 asks, 1 fault, 14 notes".
    static func breakdown(_ tally: CatchUpTally) -> String? {
        guard !tally.isEmpty else { return nil }
        return tally.ranked
            .map { "\($0.count) \(noun($0.kind, count: $0.count))" }
            .joined(separator: ", ")
    }

    /// What one kind is called when you are counting them.
    ///
    /// Not the enum's own spelling for all six: "3 dones" is not English, and
    /// a card whose whole job is to read as a sentence can't afford it. The
    /// nouns say what the kind *is* to the reader — a chat is a message, a
    /// pulse is an update — which is the same translation `BannerView` does
    /// with hue and this file does with words.
    static func noun(_ kind: NotificationEvent.Kind, count: Int) -> String {
        let singular: String
        switch kind {
        case .ask: singular = "ask"
        case .fault: singular = "fault"
        case .chat: singular = "message"
        case .pulse: singular = "update"
        case .done: singular = "finished thing"
        case .note: singular = "note"
        }
        return count == 1 ? singular : singular + "s"
    }

    /// How long the counted window is, in words: "23 minutes", "8 hours",
    /// "a day".
    ///
    /// Rounded down and coarse on purpose — this is a subtitle under a
    /// headline, not a duration anyone will do arithmetic with. It describes
    /// the *window the counts cover*, which is why "a day" is the largest
    /// thing it can say (see `maxLookback`).
    static func span(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        if minutes < 60 {
            return "\(max(minutes, 1)) minute\(minutes == 1 ? "" : "s")"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        return "a day"
    }
}
