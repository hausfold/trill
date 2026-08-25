import XCTest
@testable import Trill

/// The digest, end to end minus the display: the tally that counts what a
/// rule batched, the card that reads it out, the scope that click carries,
/// and the flush that decides when. Clock and calendar are injected
/// everywhere, so none of this needs a timer or a screen.
final class DigestTests: XCTestCase {
    /// UTC, so "03:00" means 03:00 wherever this test runs.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func at(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 25, hour: hour, minute: minute, second: second
        ))!
    }

    private func event(_ source: String, at timestamp: Date = .now) -> NotificationEvent {
        NotificationEvent(source: source, timestamp: timestamp, title: "quiet \(source)")
    }

    // MARK: - Tally

    func testTheTallyCountsPerSourceAndRanksLoudestFirst() {
        var tally = DigestTally(since: at(9))
        for _ in 0..<3 { tally.add(event("garden", at: at(9, 10))) }
        for _ in 0..<4 { tally.add(event("ci", at: at(9, 20))) }

        XCTAssertEqual(tally.total, 7)
        XCTAssertEqual(
            tally.ranked.map(\.source), ["ci", "garden"],
            "the loudest source leads — the card is a glance"
        )
        XCTAssertEqual(tally.bySource, ["ci": 4, "garden": 3])
    }

    func testTiedSourcesSortByNameSoTheCardReadsTheSameTwice() {
        var tally = DigestTally(since: at(9))
        tally.add(event("zebra"))
        tally.add(event("apple"))
        XCTAssertEqual(tally.ranked.map(\.source), ["apple", "zebra"])
    }

    func testTheWindowFollowsTheEarliestEventNotTheClock() {
        // A sender that stamps its own timestamp can be *older* than the
        // moment the tally opened; the inbox query has to reach back far
        // enough to include it.
        var tally = DigestTally(since: at(9, 30))
        tally.add(event("ci", at: at(9, 5)))
        tally.add(event("ci", at: at(9, 45)))
        XCTAssertEqual(tally.since, at(9, 5))
    }

    // MARK: - The card

    func testTheCardCountsThingsAndNamesTheSourcesBehindThem() {
        var tally = DigestTally(since: at(9))
        for _ in 0..<3 { tally.add(event("garden")) }
        for _ in 0..<4 { tally.add(event("ci")) }
        for _ in 0..<2 { tally.add(event("deploy")) }

        let card = DigestCard.event(name: DigestCard.defaultName, tally: tally, now: at(10))
        XCTAssertEqual(card.title, "9 quiet things")
        XCTAssertEqual(card.body, "ci ×4, garden ×3, deploy ×2")
        XCTAssertNil(card.subtitle, "an unnamed digest has no name worth printing")
        XCTAssertEqual(card.source, "trill")
        XCTAssertEqual(card.urgency, .low)
    }

    func testOneThingIsSingular() {
        var tally = DigestTally(since: at(9))
        tally.add(event("ci"))
        XCTAssertEqual(DigestCard.event(name: "work", tally: tally, now: at(10)).title, "1 quiet thing")
    }

    func testANamedDigestPutsItsNameOnTheCard() {
        var tally = DigestTally(since: at(9))
        tally.add(event("slack"))
        XCTAssertEqual(DigestCard.event(name: "work", tally: tally, now: at(10)).subtitle, "work")
    }

    func testTheCardCountsTheSourcesItCannotName() {
        var tally = DigestTally(since: at(9))
        for source in ["a", "b", "c", "d", "e", "f"] { tally.add(event(source)) }
        XCTAssertEqual(
            DigestCard.breakdown(tally), "a ×1, b ×1, c ×1, d ×1, +2 more",
            "a glance names \(DigestCard.namedSources) sources and counts the tail"
        )
    }

    func testTheCardsClickCarriesTheScopeItCounted() {
        var tally = DigestTally(since: at(9, 5))
        tally.add(event("ci", at: at(9, 5)))
        let card = DigestCard.event(name: "work", tally: tally, now: at(10))

        guard let action = card.actions.first else { return XCTFail("no action on the card") }
        XCTAssertEqual(action.kind, .openInbox)
        XCTAssertTrue(action.isPerformable, "a card whose click does nothing is a dead button")
        XCTAssertEqual(
            InboxScope(actionTarget: action.target),
            .digest(name: "work", since: at(9, 5)),
            "the click opens the inbox on exactly the events the card counted"
        )
        XCTAssertTrue(card.hasDefaultAction)
    }

    // MARK: - The scope, as an action target

    func testEveryScopeSurvivesTheRoundTrip() {
        for scope: InboxScope in [.all, .asks, .digest(name: "work", since: at(9))] {
            XCTAssertEqual(InboxScope(actionTarget: scope.actionTarget), scope)
        }
    }

    func testAnUnscopedActionIsThePlainWindow() {
        XCTAssertEqual(InboxScope(actionTarget: nil), .all)
        XCTAssertEqual(InboxScope(actionTarget: ""), .all)
    }

    func testADigestNameMayContainTheSeparator() {
        // Split at the *last* `@`: the name comes from the user's rules.json
        // and trill doesn't get to say what's in it.
        XCTAssertEqual(
            InboxScope(actionTarget: "digest:home@work@1000"),
            .digest(name: "home@work", since: Date(timeIntervalSince1970: 1000))
        )
    }

    func testAMalformedScopeIsRefusedRatherThanGuessed() {
        for target in ["sideways", "digest:work", "digest:@1000", "digest:work@later", "digest:"] {
            XCTAssertNil(InboxScope(actionTarget: target), "\(target) should not parse")
            XCTAssertFalse(
                NotificationEvent.Action(id: "i", label: "Inbox", kind: .openInbox, target: target)
                    .isPerformable,
                "\(target) should not draw as pressable"
            )
        }
    }

    func testAnOversizedDigestNameIsRefused() {
        let name = String(repeating: "x", count: InboxScope.nameLimit + 1)
        XCTAssertNil(InboxScope(actionTarget: "digest:\(name)@1000"))
    }

    // MARK: - Schedule

    func testTheNextFlushIsTheTopOfTheHour() {
        XCTAssertEqual(DigestSchedule.nextFlush(after: at(10, 23, 41), calendar: calendar), at(11))
    }

    func testAFlushAtTheBoundaryAsksForTheNextHourNotItsOwn() {
        // Strictly after, or the ticker hands itself the instant it just
        // served and spins.
        XCTAssertEqual(DigestSchedule.nextFlush(after: at(11), calendar: calendar), at(12))
    }

    // MARK: - The scheduler

    @MainActor
    private func scheduler(quietHours: RuleSet.QuietHours? = nil) -> DigestScheduler {
        DigestScheduler(quietHours: { quietHours })
    }

    @MainActor
    func testAFlushDrawsOneCardPerDigestAndClearsWhatItCounted() {
        let scheduler = scheduler()
        for _ in 0..<4 { scheduler.accumulate(event("ci"), digest: "work", now: at(9)) }
        for _ in 0..<3 { scheduler.accumulate(event("garden"), digest: "home", now: at(9)) }

        let cards = scheduler.flush(now: at(10), calendar: calendar)
        XCTAssertEqual(cards.map(\.subtitle), ["home", "work"], "stable order, not the dictionary's")
        XCTAssertEqual(cards.map(\.title), ["3 quiet things", "4 quiet things"])
        XCTAssertTrue(scheduler.pending.isEmpty)
        XCTAssertTrue(
            scheduler.flush(now: at(11), calendar: calendar).isEmpty,
            "an empty hour draws nothing at all"
        )
    }

    @MainActor
    func testQuietHoursHoldTheFlushRatherThanDroppingIt() {
        // 22:00–07:00. A 3am card is the one interruption this whole feature
        // exists to prevent — but the count must survive to the morning.
        let scheduler = scheduler(quietHours: .init(startMinute: 1320, endMinute: 420))
        for _ in 0..<9 { scheduler.accumulate(event("ci"), digest: "work", now: at(2)) }

        XCTAssertTrue(scheduler.flush(now: at(3), calendar: calendar).isEmpty, "silent at 3am")
        XCTAssertEqual(scheduler.pending["work"]?.total, 9, "held, not dropped")

        for _ in 0..<14 { scheduler.accumulate(event("ci"), digest: "work", now: at(6)) }
        let cards = scheduler.flush(now: at(7), calendar: calendar)
        XCTAssertEqual(
            cards.map(\.title), ["23 quiet things"],
            "the first flush after the window carries everything it held"
        )
    }

    // MARK: - What the click actually reads

    /// The card counts in memory; the list behind it is a query against rows
    /// the repository already wrote. This is that query.
    func testTheInboxQueryReturnsExactlyWhatOneCardCounted() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("digest-\(UUID().uuidString)")
            .appendingPathComponent("trill.db")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let database = try XCTUnwrap(AppDatabase(url: file))

        database.insert(event("ci", at: at(9, 10)), decision: .digest("work"))
        database.insert(event("ci", at: at(9, 40)), decision: .digest("work"))
        database.insert(event("slack", at: at(9, 50)), decision: .digest("home"))
        database.insert(event("deploy", at: at(9, 55)), decision: .banner(.primary))
        // Before the window: same digest, previous hour's card.
        database.insert(event("ci", at: at(8, 30)), decision: .digest("work"))

        let counted = database.digest(named: "work", since: at(9))
        XCTAssertEqual(counted.count, 2, "another digest's events and last hour's are not this card's")
        XCTAssertEqual(counted.map(\.decision), ["digest:work", "digest:work"])
        XCTAssertEqual(
            counted.map(\.event.timestamp), [at(9, 40), at(9, 10)],
            "newest first, like every other inbox read"
        )
    }

    @MainActor
    func testTheSchedulerKeepsACountNotACopy() {
        // The events themselves live in the inbox; holding them here would
        // make a digest rule pointed at a firehose an unbounded buffer.
        let scheduler = scheduler()
        for index in 0..<500 {
            scheduler.accumulate(event("ci", at: at(9, 0, index % 60)), digest: "work", now: at(9))
        }
        XCTAssertEqual(scheduler.pending["work"]?.total, 500)
        XCTAssertEqual(scheduler.pending["work"]?.bySource, ["ci": 500])
    }
}
