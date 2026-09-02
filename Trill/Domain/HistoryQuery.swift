import Foundation

/// What one `trill history` asks of the store — the read half of `send`.
///
/// It is a value, and its filter is pure, for the same reason every other
/// decision in this app is: the daemon side of the `history` verb is a bounded
/// fetch and this function, so "which rows answer that question" is settled in
/// a test rather than in a socket handler. The window already works this way
/// (`InboxList.rows`); this is the same shape with a CLI's flags on the front.
///
/// Nothing here is a *second* store. Everything `trill history` can say was
/// already written by `EventRepository` at ingest — the inbox, the digest
/// cards and the catch-up card all read the same rows — so adding the verb
/// added no persistence, only a way to ask.
struct HistoryQuery: Codable, Sendable, Equatable {
    /// Rows to return, after filtering. Small on purpose: the common call is
    /// an agent asking "what just fired", and a screenful answers it.
    var limit: Int = defaultLimit
    /// A sender's slug (`deploy`), or a bundle id for anything System Mirror
    /// redrew. Matched case-insensitively, the way `rules.json` matches it —
    /// one spelling of "same source" across the app.
    var source: String?
    var kind: NotificationEvent.Kind?
    /// Only what trill never put in front of anybody. The useful default is
    /// *off*: "what fired" and "what did I miss" are different questions and
    /// this verb answers the first unless asked.
    var unreadOnly: Bool = false
    /// Only what landed at or after this instant. The CLI resolves `2h` into
    /// a date before it sends, so the daemon does no clock arithmetic and the
    /// answer can't drift with how long the socket took.
    var since: Date?
    /// Free text, ANDed over the fields a row can *show* — the same haystack
    /// the inbox's search box uses, so the two never disagree about what a
    /// word matches.
    var search: String?

    static let defaultLimit = 20
    /// The most rows one call may return, and the number the daemon reads out
    /// of the database before filtering. One constant for both, because a
    /// `--limit` larger than the scan could never be filled and would just be
    /// a promise the verb quietly breaks.
    ///
    /// It is `InboxList.fetchLimit` deliberately: this verb and the window
    /// look at exactly the same slice of history, so the same question asked
    /// two ways can't get two answers.
    static let scanLimit = InboxList.fetchLimit

    /// Longest `--search` the wire will carry. A sanity bound, like
    /// `InboxScope.nameLimit`: anything local can write to trill's socket, and
    /// an unbounded string that ends up in a `contains` per row has no
    /// business arriving from there.
    static let searchLimit = 200

    /// What the daemon will actually honour. A hand-written socket client is
    /// not the CLI and may ask for a million rows; clamping here means the
    /// query the filter sees is always one this verb can keep its word about.
    func clamped() -> HistoryQuery {
        var copy = self
        copy.limit = min(max(1, limit), Self.scanLimit)
        copy.search = search.map { String($0.prefix(Self.searchLimit)) }
        return copy
    }

    /// `--since` as a person writes it: a duration back from now (`30m`,
    /// `2h`, `7d`, or bare seconds — `RuleSet.Resolver`'s spelling, because a
    /// second one would be a second thing to remember) or an absolute
    /// ISO-8601 instant, which is what a script that already has a timestamp
    /// will hand us.
    static func instant(_ raw: String, now: Date = .now) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if let parsed = ISO8601DateFormatter().date(from: text) { return parsed }
        // A duration, and only a *positive* one: `--since -2h` is a typo for
        // a window in the future, which no row can be in.
        guard let seconds = RuleSet.Resolver.seconds(from: text), seconds > 0 else { return nil }
        return now.addingTimeInterval(-seconds)
    }

    /// The rows that answer this query, newest first — the order the fetch
    /// already arrives in and the order the answer keeps.
    ///
    /// Threads are *not* folded. The window folds them because a list you
    /// read with your eyes shouldn't repeat one conversation fifteen times;
    /// a script wants the fifteen, and it can fold them itself on the
    /// `thread` key every row carries.
    func filter(_ entries: [InboxEntry]) -> [InboxEntry] {
        let terms = InboxList.terms(in: search ?? "")
        let wanted = source?.lowercased()
        return entries.filter { entry in
            if let wanted, entry.event.source.lowercased() != wanted { return false }
            if let kind, entry.event.kind != kind { return false }
            if unreadOnly, !entry.isUnread { return false }
            if let since, entry.event.timestamp < since { return false }
            return InboxList.matches(entry.event, terms: terms)
        }
        .prefix(max(1, limit))
        .map { $0 }
    }
}

/// Decoding, written out rather than synthesized, for the reason
/// `NotificationEvent`'s is: **a key the wire doesn't name is that key at its
/// default.** The synthesized initializer would ignore the defaults above and
/// insist on every key, so `{"limit": 5}` — a perfectly clear request, and the
/// shape a hand-written client will send — would come back as "invalid JSON".
/// A partial query is the normal case, exactly as a partial `config.json` is.
///
/// This is decode-only on purpose: what trill *writes* is the whole object, so
/// the CLI and the daemon never disagree about what an absent key meant.
extension HistoryQuery {
    enum CodingKeys: String, CodingKey {
        case limit, source, kind, unreadOnly, since, search
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            limit: try container.decodeIfPresent(Int.self, forKey: .limit) ?? Self.defaultLimit,
            source: try container.decodeIfPresent(String.self, forKey: .source),
            kind: try container.decodeIfPresent(NotificationEvent.Kind.self, forKey: .kind),
            unreadOnly: try container.decodeIfPresent(Bool.self, forKey: .unreadOnly) ?? false,
            since: try container.decodeIfPresent(Date.self, forKey: .since),
            search: try container.decodeIfPresent(String.self, forKey: .search)
        )
    }
}

/// One `history` read: the rows that answered, and how many the fetch looked
/// at to find them.
///
/// `scanned` is not a statistic — it is the verb admitting its own edge. The
/// fetch is bounded at `HistoryQuery.scanLimit`, so a query that filtered a
/// full scan down to three rows may have a fourth just past the cap, and a
/// listing that said nothing about that would be claiming a completeness it
/// never had. The window says so the same way when it fills.
struct HistoryPage: Sendable, Equatable {
    var entries: [InboxEntry]
    var scanned: Int
}
