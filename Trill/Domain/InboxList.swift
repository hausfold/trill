import Foundation

/// One row of history as the inbox reads it: the event, the delivery label
/// the repository stamped on it, and whether trill ever put it in front of
/// the user.
///
/// `readAt` is nil for everything that was *held back* — quiet hours, an
/// `inbox` rule, a digest tally — and stamped for anything drawn as a banner
/// (see `AppDatabase.insert`). So "unread" here does not mean "you haven't
/// looked at this list"; it means "this never interrupted you", which is the
/// only reading that makes the count worth putting in a title bar.
struct InboxEntry: Sendable, Identifiable, Equatable {
    let event: NotificationEvent
    /// `banner`, `inbox`, or `digest:<name>` — what `PolicyEngine` decided.
    let decision: String
    var readAt: Date?

    var id: String { event.id }
    var isUnread: Bool { readAt == nil }

    init(event: NotificationEvent, decision: String, readAt: Date? = nil) {
        self.event = event
        self.decision = decision
        self.readAt = readAt
    }
}

/// A thread, collapsed. The newest event is the face and the rest hang
/// behind it — the same shape `BannerQueue.Entry` gives a coalesced banner,
/// for the same reason: a thread is one thing that happened several times,
/// and a list that repeats it fifteen times is a list you stop reading.
///
/// An event with no `thread` is a row of one; nothing is invented to group
/// it, because the inbox groups by the key the *sender* chose and the
/// compositor already folds on (`BannerQueue.enqueue`), never by a guess at
/// what looks similar.
struct InboxRow: Identifiable, Equatable {
    /// Newest event in the thread.
    let face: InboxEntry
    /// The rest, newest first. The face is not among them.
    let mates: [InboxEntry]

    var id: String { face.id }
    var entries: [InboxEntry] { [face] + mates }
    var thread: String? { face.event.thread }
    var isThread: Bool { !mates.isEmpty }
    var unreadCount: Int { entries.filter(\.isUnread).count }
    var isUnread: Bool { unreadCount > 0 }
    /// Every id this row stands for — what a click marks read.
    var ids: [String] { entries.map(\.id) }
}

/// Turning stored history into what the inbox draws: scope, search, threads.
/// Pure, so all of it is testable without a display — the window is a view
/// onto this, and holds no filtering logic of its own.
enum InboxList {
    /// How many rows of history one inbox window reads. Search runs over
    /// what was fetched, not over the whole table: with a 30-day retention
    /// this is the practical whole of it, and a bounded fetch keeps a
    /// keystroke from turning into a query. The window says so when it hits
    /// the cap rather than silently pretending the tail isn't there.
    static let fetchLimit = 1000

    /// The scope's own filter, applied after the query that fetched it.
    /// `.all` and `.digest` are already exactly what their query returned;
    /// `.asks` is a kind filter over the plain list.
    static func inScope(_ entries: [InboxEntry], scope: InboxScope) -> [InboxEntry] {
        switch scope {
        case .all, .digest, .since:
            entries
        case .asks:
            entries.filter { $0.event.kind == .ask }
        }
    }

    /// Split a search field into terms. Whitespace-separated and ANDed:
    /// typing two words narrows rather than widens, which is what a person
    /// typing a second word means every time.
    static func terms(in query: String) -> [String] {
        query.lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    /// Does one event match every term? The haystack is everything the row
    /// can *show* — source, title, subtitle, body, thread — and nothing it
    /// can't: ids and resolution keys are machinery, and matching them would
    /// make a search for "pr" turn up rows with no "pr" anywhere on them.
    static func matches(_ event: NotificationEvent, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let haystack = [event.source, event.title, event.subtitle, event.body, event.thread]
            .compactMap { $0 }
            .joined(separator: "\u{1}")
            .lowercased()
        return terms.allSatisfy(haystack.contains)
    }

    /// Scope → search → thread grouping, in that order.
    ///
    /// Search filters *events*, not threads: a hit inside a fifteen-message
    /// thread shows that message, and the fourteen it arrived beside stay
    /// out of the way. So a row's count under a query is a count of matches,
    /// which is the number the person searching is actually asking for.
    static func rows(
        from entries: [InboxEntry],
        scope: InboxScope = .all,
        query: String = "",
        unreadOnly: Bool = false
    ) -> [InboxRow] {
        let terms = terms(in: query)
        let filtered = inScope(entries, scope: scope).filter { entry in
            (!unreadOnly || entry.isUnread) && matches(entry.event, terms: terms)
        }
        return group(filtered)
    }

    /// Fold thread-mates into their newest member. `entries` arrives newest
    /// first (the database orders it) and rows keep that order, so a thread
    /// sits where its *latest* message would have sat — an inbox that
    /// reorders itself around old traffic is one you lose your place in.
    static func group(_ entries: [InboxEntry]) -> [InboxRow] {
        var faces: [InboxEntry] = []
        var mates: [String: [InboxEntry]] = [:]
        var seenThreads: Set<String> = []

        for entry in entries {
            guard let thread = entry.event.thread else {
                faces.append(entry)
                continue
            }
            if seenThreads.insert(thread).inserted {
                faces.append(entry)
            } else {
                mates[thread, default: []].append(entry)
            }
        }

        return faces.map { face in
            InboxRow(
                face: face,
                mates: face.event.thread.flatMap { mates[$0] } ?? []
            )
        }
    }

    /// The actions the inbox draws as pills for one event.
    ///
    /// More generous than a banner's `pillActions` — the card is a glance and
    /// stops at three, the inbox is where the rest survive — but narrower in
    /// one place: **`reply` never draws here.** A reply is a line written back
    /// down the socket the ask arrived on, and history has no socket; the
    /// caller that was blocked on it is long gone (`AskBroker`), so the pill
    /// would be a button that answers nobody. Same reason a fin restored from
    /// the ledge after a restart loses its pills.
    static func pills(for event: NotificationEvent) -> [NotificationEvent.Action] {
        event.actions.filter { $0.isPerformable && $0.kind != .reply }
    }
}
