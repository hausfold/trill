import XCTest
@testable import Trill

/// The inbox, minus the window: which events a scope admits, what a search
/// narrows to, how threads fold, which actions survive into a list, and what
/// "unread" is allowed to mean. All of it is `InboxList` and `AppDatabase`,
/// both testable without a display — the view holds no filtering of its own.
final class InboxTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_756_000_000)

    private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

    private func event(
        id: String = UUID().uuidString,
        source: String = "ci",
        title: String = "something happened",
        body: String? = nil,
        thread: String? = nil,
        kind: NotificationEvent.Kind = .note,
        actions: [NotificationEvent.Action] = [],
        at offset: TimeInterval = 0
    ) -> NotificationEvent {
        NotificationEvent(
            id: id, source: source, timestamp: at(offset), title: title,
            body: body, thread: thread, kind: kind, actions: actions
        )
    }

    private func entry(
        _ event: NotificationEvent, decision: String = "inbox", read: Bool = false
    ) -> InboxEntry {
        InboxEntry(event: event, decision: decision, readAt: read ? epoch : nil)
    }

    /// Newest first, the order every inbox read arrives in.
    private func entries(_ events: [NotificationEvent]) -> [InboxEntry] {
        events.sorted { $0.timestamp > $1.timestamp }.map { entry($0) }
    }

    // MARK: - Threads

    func testAThreadFoldsIntoItsNewestEventAndKeepsTheRest() {
        let rows = InboxList.group(entries([
            event(id: "a", title: "build started", thread: "pr-142", at: 10),
            event(id: "b", title: "tests green", thread: "pr-142", at: 20),
            event(id: "c", title: "merged", thread: "pr-142", at: 30),
        ]))

        XCTAssertEqual(rows.count, 1, "one thread is one row")
        XCTAssertEqual(rows[0].face.id, "c", "the newest event is the face")
        XCTAssertEqual(rows[0].mates.map(\.id), ["b", "a"], "the rest hang behind it, newest first")
        XCTAssertEqual(rows[0].entries.count, 3)
        XCTAssertTrue(rows[0].isThread)
    }

    func testAnUnthreadedEventIsARowOfOne() {
        // Nothing is invented to group by: the inbox folds on the key the
        // sender chose and the compositor already coalesces on, never on a
        // guess at what looks similar.
        let rows = InboxList.group(entries([
            event(id: "a", source: "ci", title: "deploy failed", at: 10),
            event(id: "b", source: "ci", title: "deploy failed", at: 20),
        ]))

        XCTAssertEqual(rows.count, 2, "same source and title is not a thread")
        XCTAssertTrue(rows.allSatisfy { !$0.isThread })
    }

    func testARowSitsWhereItsNewestMessageWould() {
        let rows = InboxList.group(entries([
            event(id: "old-thread-1", thread: "chat", at: 10),
            event(id: "loner", at: 20),
            event(id: "old-thread-2", thread: "chat", at: 30),
        ]))

        XCTAssertEqual(
            rows.map(\.id), ["old-thread-2", "loner"],
            "a thread rides its latest message — an inbox that reorders around old traffic is one you lose your place in"
        )
    }

    // MARK: - Search

    func testSearchMatchesEverythingARowCanShow() {
        let target = event(
            source: "garden", title: "hose left on", body: "the tap by the shed", thread: "watering"
        )
        for term in ["garden", "hose", "shed", "watering", "HOSE"] {
            XCTAssertTrue(
                InboxList.matches(target, terms: InboxList.terms(in: term)),
                "\(term) is on the row, so it has to match"
            )
        }
    }

    func testSearchIgnoresMachineryTheRowNeverDraws() {
        let target = event(id: "abc-123", source: "ci", title: "build ok")
        XCTAssertFalse(
            InboxList.matches(target, terms: InboxList.terms(in: "abc-123")),
            "matching ids would turn up rows with the term nowhere on them"
        )
    }

    func testTwoWordsNarrowRatherThanWiden() {
        let target = event(source: "ci", title: "deploy failed", body: "staging")
        XCTAssertTrue(InboxList.matches(target, terms: InboxList.terms(in: "deploy staging")))
        XCTAssertFalse(
            InboxList.matches(target, terms: InboxList.terms(in: "deploy production")),
            "a second word means AND every time somebody types one"
        )
    }

    func testSearchNarrowsAThreadToItsMatchesNotItsWholeThread() {
        let rows = InboxList.rows(
            from: entries([
                event(id: "a", title: "build started", thread: "pr-142", at: 10),
                event(id: "b", title: "tests green", thread: "pr-142", at: 20),
                event(id: "c", title: "tests green again", thread: "pr-142", at: 30),
            ]),
            query: "tests"
        )

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows[0].entries.map(\.id), ["c", "b"],
            "a row's count under a query is a count of matches — the number the searcher asked for"
        )
    }

    // MARK: - Scope

    func testTheAsksScopeIsAKindFilter() {
        let all = entries([
            event(id: "ask", kind: .ask, at: 30),
            event(id: "note", kind: .note, at: 20),
            event(id: "fault", kind: .fault, at: 10),
        ])
        XCTAssertEqual(InboxList.rows(from: all, scope: .asks).map(\.id), ["ask"])
        XCTAssertEqual(InboxList.rows(from: all, scope: .all).count, 3)
    }

    /// The whole promise of "the inbox is the ledge's overflow": the ask a
    /// sixth one evicted is *here*, findable by the same scope that shows the
    /// five still parked. Nothing about eviction touches history.
    func testAnAskEvictedFromTheLedgeIsStillInTheAsksScope() {
        let asks = (0..<6).map {
            entry(event(id: "ask-\($0)", kind: .ask, at: TimeInterval($0) * 10))
        }.reversed()

        let rows = InboxList.rows(from: Array(asks), scope: .asks)
        XCTAssertEqual(rows.count, 6, "the ledge holds five; the inbox holds all six")
        XCTAssertEqual(rows.last?.id, "ask-0", "the one that yielded its fin is the oldest row")
    }

    // MARK: - Unread

    func testUnreadOnlyKeepsWhatTrillNeverPutInFrontOfYou() {
        let list = [
            entry(event(id: "quiet", at: 30), decision: "inbox", read: false),
            entry(event(id: "seen", at: 20), decision: "banner", read: true),
            entry(event(id: "digested", at: 10), decision: "digest:work", read: false),
        ]
        XCTAssertEqual(
            InboxList.rows(from: list, unreadOnly: true).map(\.id), ["quiet", "digested"]
        )
    }

    func testAThreadIsUnreadWhileAnyOfItIs() {
        let row = InboxList.group([
            entry(event(id: "c", thread: "t", at: 30), read: true),
            entry(event(id: "b", thread: "t", at: 20), read: true),
            entry(event(id: "a", thread: "t", at: 10), read: false),
        ])[0]

        XCTAssertEqual(row.unreadCount, 1)
        XCTAssertTrue(row.isUnread, "a folded thread can't hide an unread message inside itself")
    }

    // MARK: - Pills

    private func action(
        _ label: String, _ kind: NotificationEvent.Action.Kind, _ target: String?
    ) -> NotificationEvent.Action {
        NotificationEvent.Action(id: label, label: label, kind: kind, target: target)
    }

    func testTheInboxDrawsEveryPerformableActionNotJustThree() {
        let event = event(actions: [
            action("One", .openURL, "https://example.com/1"),
            action("Two", .openURL, "https://example.com/2"),
            action("Three", .openURL, "https://example.com/3"),
            action("Four", .openURL, "https://example.com/4"),
        ])
        XCTAssertEqual(event.pillActions.count, NotificationEvent.Limits.drawnActions, "the card is a glance")
        XCTAssertEqual(
            InboxList.pills(for: event).map(\.label), ["One", "Two", "Three", "Four"],
            "the inbox is where the rest survive"
        )
    }

    func testTheInboxDrawsNoReplyPills() {
        // A reply is a line written back down the socket the ask arrived on,
        // and history has no socket — the caller is long gone.
        let event = event(kind: .ask, actions: [
            action("Allow", .reply, "0"),
            action("Deny", .reply, "1"),
            action("Open PR", .openURL, "https://example.com/pr"),
        ])
        XCTAssertEqual(InboxList.pills(for: event).map(\.label), ["Open PR"])
    }

    func testTheInboxDrawsNoDeadButtons() {
        let event = event(actions: [
            action("Broken", .openURL, "ssh://nope"),
            action("Hook", .command, "rebuild"),
            action("Good", .openURL, "https://example.com"),
        ])
        XCTAssertEqual(InboxList.pills(for: event).map(\.label), ["Good"])
    }

    func testASingleActionStillDrawsAPill() {
        // The banner rides one action as an inline label because the card
        // click *is* it; the inbox has no such click, so it needs the button.
        let event = event(actions: [action("Open", .openURL, "https://example.com")])
        XCTAssertTrue(event.pillActions.isEmpty)
        XCTAssertEqual(InboxList.pills(for: event).map(\.label), ["Open"])
    }

    // MARK: - Persistence

    private func temporaryDatabase() throws -> (AppDatabase, URL) {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("inbox-\(UUID().uuidString)")
            .appendingPathComponent("trill.db")
        return (try XCTUnwrap(AppDatabase(url: file)), file.deletingLastPathComponent())
    }

    func testADrawnBannerArrivesReadAndEverythingHeldBackArrivesUnread() throws {
        let (database, directory) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        database.insert(event(id: "shown", at: 30), decision: .banner, now: at(30))
        database.insert(event(id: "quiet", at: 20), decision: .inboxOnly, now: at(20))
        database.insert(event(id: "counted", at: 10), decision: .digest("work"), now: at(10))

        let stored = database.recent(limit: 10)
        XCTAssertEqual(stored.filter(\.isUnread).map(\.id), ["quiet", "counted"])
        XCTAssertEqual(
            stored.first(where: { $0.id == "shown" })?.readAt, at(30),
            "a banner was on a screen — that is the closest thing trill has to seen"
        )
    }

    func testMarkingReadSurvivesTheWindowClosing() throws {
        let (database, directory) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        database.insert(event(id: "a", at: 20), decision: .inboxOnly)
        database.insert(event(id: "b", at: 10), decision: .inboxOnly)
        database.setRead(true, ids: ["a"], now: at(100))

        XCTAssertEqual(database.recent(limit: 10).filter(\.isUnread).map(\.id), ["b"])
        XCTAssertEqual(database.recent(limit: 10).first?.readAt, at(100))

        database.setRead(false, ids: ["a"])
        XCTAssertEqual(
            database.recent(limit: 10).filter(\.isUnread).map(\.id), ["a", "b"],
            "marking unread has to put the dot back, or the context menu is a lie"
        )
    }

    /// A database written before the inbox grew unread state has every column
    /// but `read_at`. Opening it must add the column, not fail the read — the
    /// rows are the user's history.
    func testAnOlderDatabaseGainsTheColumnRatherThanLosingItsRows() throws {
        let (database, directory) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        database.insert(event(id: "old", at: 10), decision: .inboxOnly)
        XCTAssertEqual(database.recent(limit: 10).count, 1)

        // Reopening runs the same migration a second time; it must be a no-op.
        let reopened = try XCTUnwrap(AppDatabase(url: directory.appendingPathComponent("trill.db")))
        XCTAssertEqual(reopened.recent(limit: 10).map(\.id), ["old"])
        XCTAssertTrue(reopened.recent(limit: 10).allSatisfy(\.isUnread))
    }
}
