import Foundation

/// The pending side of `delivery: digest` — what has been batched under one
/// name since the last flush.
///
/// A **tally**, not a list of events: the card needs a total, a per-source
/// breakdown and the instant the window opened, and nothing else. It is also
/// the only shape that stays bounded — a digest rule pointed at a firehose
/// would otherwise accumulate every event the user asked *not* to be shown,
/// in memory, for an hour. The events themselves are already in the inbox,
/// which is exactly where the card's click sends you.
struct DigestTally: Equatable, Sendable {
    private(set) var total = 0
    private(set) var bySource: [String: Int] = [:]
    /// The oldest event timestamp in the window — the `since` the inbox
    /// scopes to. Taken from the events rather than the clock, so a sender
    /// that stamps its own (slightly earlier) timestamp still lands inside
    /// the window it was counted in.
    private(set) var since: Date

    init(since: Date) {
        self.since = since
    }

    mutating func add(_ event: NotificationEvent) {
        total += 1
        bySource[event.source, default: 0] += 1
        since = min(since, event.timestamp)
    }

    /// Sources, biggest first, ties broken by name. Biggest-first because the
    /// card is a glance and the loudest source is the answer to "what was
    /// that"; name-sorted ties so the same tally reads the same way twice.
    var ranked: [(source: String, count: Int)] {
        bySource
            .map { (source: $0.key, count: $0.value) }
            .sorted { $0.count == $1.count ? $0.source < $1.source : $0.count > $1.count }
    }
}

/// Builds the one card a flush puts on screen.
///
/// Pure, and deliberately not a provider: a digest card is composed *by*
/// trill out of rows it already has, so it never re-enters the repository —
/// it would be re-policied (a rule matching `source: trill` could digest the
/// digest), re-persisted, and re-deduped for no gain. It goes straight to the
/// `BannerQueue`, the same way the queue is the truth for everything else.
enum DigestCard {
    /// The digest name a rule gets when it says `"delivery": "digest"` and
    /// names none — see `RuleSet.Rule.Delivery`. Unnamed digests don't put
    /// their name on the card; there is nothing to tell apart.
    static let defaultName = "default"

    /// Sources spelled out before the card gives up and counts the rest.
    static let namedSources = 4

    static func event(
        name: String,
        tally: DigestTally,
        now: Date = .now
    ) -> NotificationEvent {
        NotificationEvent(
            // Deterministic in `now`, so a test can predict it and two
            // digests flushing on the same tick can't collide.
            id: "digest:\(name):\(Int(now.timeIntervalSince1970))",
            source: "trill",
            timestamp: now,
            title: title(total: tally.total),
            subtitle: name == defaultName ? nil : name,
            body: breakdown(tally),
            symbol: "tray.full",
            // One fin per digest name: a second flush of the *same* digest
            // inside the coalesce window folds into the first rather than
            // stacking two cards that say the same thing.
            thread: "trill.digest.\(name)",
            kind: .note,
            urgency: .low,
            actions: [
                .init(
                    id: "inbox",
                    label: "Open inbox",
                    kind: .openInbox,
                    target: InboxScope.digest(name: name, since: tally.since).actionTarget
                )
            ]
        )
    }

    /// "9 quiet things" — quiet because that is what the rule did to them.
    static func title(total: Int) -> String {
        "\(total) quiet thing\(total == 1 ? "" : "s")"
    }

    /// "ci ×4, garden ×3, deploy ×1 +2 more" — the sources behind the count.
    static func breakdown(_ tally: DigestTally) -> String? {
        let ranked = tally.ranked
        guard !ranked.isEmpty else { return nil }
        var parts = ranked.prefix(namedSources).map { "\($0.source) ×\($0.count)" }
        let unnamed = ranked.count - parts.count
        if unnamed > 0 { parts.append("+\(unnamed) more") }
        return parts.joined(separator: ", ")
    }
}

/// When the next flush is due. Hourly, on the hour — the schedule is trill's,
/// not the rule's: a digest name says *what* batches, and every batch drains
/// at the same predictable moment so "I'll see it at the top of the hour" is
/// true of all of them.
enum DigestSchedule {
    /// The next top-of-the-hour strictly after `date`. Strictly, because the
    /// caller flushes *at* the boundary and then asks for the next one — a
    /// non-strict answer would hand back the instant it just served and spin.
    static func nextFlush(after date: Date, calendar: Calendar = .current) -> Date {
        calendar.nextDate(
            after: date,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? date.addingTimeInterval(3600)
    }
}
