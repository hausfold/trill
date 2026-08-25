import XCTest
@testable import Trill

/// The quiet launch, end to end minus the screen: the presence log that
/// decides when an absence began and ended, the window it hands over, the
/// counts behind the card, and the sentence the card reads out.
///
/// Every clock is injected, so a whole night — lock, sleep, wake, reboot,
/// login — runs in a millisecond and none of it needs a lock screen.
final class CatchUpTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A time on the night of the 24th→25th, so "23:00" and "08:00" are the
    /// two ends of the case this whole feature is about.
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: day, hour: hour, minute: minute
        ))!
    }

    private func event(
        _ id: String, kind: NotificationEvent.Kind = .note, at timestamp: Date
    ) -> NotificationEvent {
        NotificationEvent(id: id, source: "ci", timestamp: timestamp, title: id, kind: kind)
    }

    // MARK: - The presence log

    func testLockingAndUnlockingIsOneAbsence() {
        var log = PresenceLog(lastPresent: at(24, 22))
        XCTAssertNil(log.note(.locked, at: at(24, 23)), "leaving is not an event, arriving is")

        let window = log.note(.unlocked, at: at(25, 8))
        XCTAssertEqual(window, at(24, 23)...at(25, 8))
        XCTAssertFalse(log.isAway)
    }

    func testTheFirstDepartureWinsTheTimestamp() {
        // Lock at 23:00, sleep at 23:30. That is one absence beginning at
        // 23:00 — restamping it would silently drop everything that arrived
        // in the first half hour, which on a Mac with agents on it is
        // exactly the traffic worth reporting.
        var log = PresenceLog(lastPresent: at(24, 22))
        _ = log.note(.locked, at: at(24, 23))
        _ = log.note(.slept, at: at(24, 23, 30))

        XCTAssertEqual(log.note(.unlocked, at: at(25, 8)), at(24, 23)...at(25, 8))
    }

    func testWakingOntoALockScreenIsNotComingBack() {
        // The card would be drawn, time out and be gone before the password
        // was typed. The unlock is the return.
        var log = PresenceLog(lastPresent: at(24, 22))
        _ = log.note(.locked, at: at(24, 23))
        _ = log.note(.slept, at: at(24, 23, 1))

        XCTAssertNil(log.note(.woke, at: at(25, 8)))
        XCTAssertTrue(log.isAway)
        XCTAssertEqual(log.note(.unlocked, at: at(25, 8, 1)), at(24, 23)...at(25, 8, 1))
    }

    func testWakingAMacThatNeverLockedIsComingBack() {
        // No password on wake means no unlock notification will ever arrive;
        // for that Mac the wake *is* the return, or it never gets a card.
        var log = PresenceLog(lastPresent: at(24, 22))
        _ = log.note(.slept, at: at(24, 23))

        XCTAssertEqual(log.note(.woke, at: at(25, 8)), at(24, 23)...at(25, 8))
    }

    func testFastUserSwitchingIsAnAbsence() {
        var log = PresenceLog(lastPresent: at(25, 9))
        _ = log.note(.switchedAway, at: at(25, 10))
        XCTAssertEqual(log.note(.switchedBack, at: at(25, 12)), at(25, 10)...at(25, 12))
    }

    func testARelaunchWithNobodyGoneReportsNothing() {
        // A crash or an update while someone was sitting here. Nothing was
        // missed, so there is nothing to say.
        var log = PresenceLog(lastPresent: at(25, 9))
        XCTAssertNil(log.note(.launched, at: at(25, 9, 1)))
    }

    func testARebootInTheNightStillReportsFromTheLock() {
        // The case that needs the log on disk: locked at 23:00, traffic until
        // the Mac reboots at 03:00, logged into at 08:00. The window has to
        // open at 23:00 — quitting is a departure, and departures don't
        // restamp.
        var log = PresenceLog(lastPresent: at(24, 22))
        _ = log.note(.locked, at: at(24, 23))
        _ = log.note(.quitting, at: at(25, 3))

        let store = PresenceStore(defaults: scratchDefaults())
        store.save(log)
        var restored = try! XCTUnwrap(store.load())

        XCTAssertEqual(restored.note(.launched, at: at(25, 8)), at(24, 23)...at(25, 8))
    }

    func testAMacThatHasNeverRunThisBuildHasNoAbsenceToReport() {
        // Not "away since the epoch": the first launch would count every
        // unread row in the retention window as last night's news.
        XCTAssertNil(PresenceStore(defaults: scratchDefaults()).load())
    }

    private func scratchDefaults() -> UserDefaults {
        let suite = "trill.catchup.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - The window

    func testACoffeeBreakEarnsNoCard() {
        XCTAssertNil(CatchUpCard.window(from: at(25, 9), to: at(25, 9, 2)))
    }

    func testALongAbsenceIsCountedFromADayAgoAtMost() {
        // A week away is not a bigger paper, it is an archive — and the
        // inbox is the archive.
        let window = CatchUpCard.window(from: at(18, 9), to: at(25, 9))
        XCTAssertEqual(window?.lowerBound, at(24, 9))
        XCTAssertEqual(window?.upperBound, at(25, 9))
    }

    func testANormalNightIsCountedWhole() {
        let window = CatchUpCard.window(from: at(24, 23), to: at(25, 8))
        XCTAssertEqual(window, at(24, 23)...at(25, 8))
    }

    // MARK: - The tally

    func testKindsReadInTriageOrderNotCountOrder() {
        // The digest ranks its sources loudest-first because it answers
        // "what was all that noise". This answers "what do I have to deal
        // with", and one ask outranks fourteen notes.
        let tally = CatchUpTally(
            since: at(24, 23), span: 9 * 3600,
            counts: [.note: 14, .ask: 2, .fault: 1]
        )
        XCTAssertEqual(tally.ranked.map(\.kind), [.ask, .fault, .note])
        XCTAssertEqual(tally.total, 17)
        XCTAssertEqual(CatchUpCard.breakdown(tally), "2 asks, 1 fault, 14 notes")
    }

    func testTheSentenceIsEnglishForEveryKind() {
        let tally = CatchUpTally(
            since: at(24, 23), span: 3600,
            counts: [.ask: 1, .fault: 2, .chat: 3, .pulse: 1, .done: 2, .note: 1]
        )
        XCTAssertEqual(
            CatchUpCard.breakdown(tally),
            "1 ask, 2 faults, 3 messages, 1 update, 2 finished things, 1 note"
        )
    }

    func testTheSpanDescribesTheWindowInWords() {
        XCTAssertEqual(CatchUpCard.span(90), "1 minute")
        XCTAssertEqual(CatchUpCard.span(23 * 60), "23 minutes")
        XCTAssertEqual(CatchUpCard.span(3600), "1 hour")
        XCTAssertEqual(CatchUpCard.span(9 * 3600), "9 hours")
        XCTAssertEqual(
            CatchUpCard.span(CatchUpCard.maxLookback), "a day",
            "the largest thing it can say, because it is the largest window it counts"
        )
    }

    // MARK: - The card

    func testAQuietNightDrawsNothing() {
        let tally = CatchUpTally(since: at(24, 23), span: 9 * 3600)
        XCTAssertNil(
            CatchUpCard.card(for: tally),
            "an unlock that always produces a card is an unlock you stop reading"
        )
    }

    func testTheCardCarriesItsOwnWindowToTheInbox() throws {
        let tally = CatchUpTally(since: at(24, 23), span: 9 * 3600, counts: [.ask: 2, .note: 14])
        let card = try XCTUnwrap(CatchUpCard.card(for: tally, now: at(25, 8)))

        XCTAssertEqual(card.title, "While you were away")
        XCTAssertEqual(card.subtitle, "9 hours")
        XCTAssertEqual(card.body, "2 asks, 14 notes")
        XCTAssertEqual(card.urgency, .low)
        XCTAssertEqual(card.thread, CatchUpCard.thread)

        let action = try XCTUnwrap(card.actions.first)
        XCTAssertEqual(action.kind, .openInbox)
        XCTAssertEqual(InboxScope(actionTarget: action.target), .since(at(24, 23)))
    }

    func testTwoCardsOnTheSameTickWouldFoldRatherThanStack() {
        let tally = CatchUpTally(since: at(24, 23), span: 3600, counts: [.note: 1])
        let first = CatchUpCard.card(for: tally, now: at(25, 8))
        let second = CatchUpCard.card(for: tally, now: at(25, 8))
        XCTAssertEqual(first?.id, second?.id)
        XCTAssertEqual(first?.thread, second?.thread)
    }

    // MARK: - The scope

    func testTheScopeRoundTripsThroughAnActionTarget() {
        let scope = InboxScope.since(at(24, 23))
        XCTAssertEqual(InboxScope(actionTarget: scope.actionTarget), scope)
    }

    func testAScopeTrillCannotReadIsRefused() {
        XCTAssertNil(InboxScope(actionTarget: "since:yesterday"))
    }

    func testTheCatchUpWindowOpensOnWhatTheCardCounted() {
        // The card counted what trill never showed you; a click landing on a
        // longer list would make its number look wrong.
        XCTAssertTrue(InboxScope.since(at(24, 23)).opensUnreadOnly)
        XCTAssertFalse(InboxScope.all.opensUnreadOnly)
        XCTAssertFalse(InboxScope.digest(name: "work", since: at(24, 23)).opensUnreadOnly)
    }

    // MARK: - The counting

    private func temporaryDatabase() throws -> (AppDatabase, URL) {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("catchup-\(UUID().uuidString)")
            .appendingPathComponent("trill.db")
        return (try XCTUnwrap(AppDatabase(url: file)), file.deletingLastPathComponent())
    }

    func testABannerDrawnAtALockedScreenWasNeverPutInFrontOfAnybody() throws {
        let (database, directory) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        database.insert(event("watched", at: at(25, 9)), decision: .banner(.primary), seen: true)
        database.insert(event("empty-room", at: at(25, 2)), decision: .banner(.primary), seen: false)

        XCTAssertEqual(
            database.recent(limit: 10).filter(\.isUnread).map(\.id), ["empty-room"],
            "a card that played to a locked screen is not a card you have seen"
        )
    }

    func testTheCountsAreWhatLandedUnseenInsideTheWindow() throws {
        let (database, directory) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Before the absence, seen: not news.
        database.insert(event("daytime", at: at(24, 15)), decision: .banner(.primary), seen: true)
        // During, all unseen — a banner to a locked screen, a quiet rule, a
        // digest tally. All three are things you would otherwise never learn.
        database.insert(event("night-ask", kind: .ask, at: at(25, 1)), decision: .banner(.primary), seen: false)
        database.insert(event("night-ask-2", kind: .ask, at: at(25, 2)), decision: .inboxOnly)
        database.insert(event("night-fault", kind: .fault, at: at(25, 3)), decision: .digest("work"))
        database.insert(event("night-note", at: at(25, 4)), decision: .inboxOnly)
        // During, but seen — someone got up at 4am and read it.
        database.insert(event("night-seen", at: at(25, 4, 30)), decision: .banner(.primary), seen: true)

        XCTAssertEqual(
            database.missedCounts(since: at(24, 23)),
            [.ask: 2, .fault: 1, .note: 1]
        )
    }

    func testTheClickLandsOnTheRowsBehindTheNumber() throws {
        let (database, directory) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        database.insert(event("before", at: at(24, 15)), decision: .inboxOnly)
        database.insert(event("during", at: at(25, 1)), decision: .inboxOnly)

        XCTAssertEqual(database.events(since: at(24, 23)).map(\.id), ["during"])
    }

    @MainActor
    func testTheReporterDeclinesQuietlyAndForGoodReasons() throws {
        let (database, directory) = try temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        database.insert(event("night", kind: .fault, at: at(25, 1)), decision: .inboxOnly)

        var cards: [NotificationEvent] = []
        var enabled = true
        var history: AppDatabase? = database
        let reporter = CatchUpReporter(enabled: { enabled })
        reporter.database = { history }
        reporter.onCard = { cards.append($0) }

        reporter.report(returned: at(25, 8)...at(25, 8, 1), now: at(25, 8, 1))
        XCTAssertTrue(cards.isEmpty, "a coffee break is not an absence")

        enabled = false
        reporter.report(returned: at(24, 23)...at(25, 8), now: at(25, 8))
        XCTAssertTrue(cards.isEmpty, "the switch is read live")

        enabled = true
        history = nil
        reporter.report(returned: at(24, 23)...at(25, 8), now: at(25, 8))
        XCTAssertTrue(cards.isEmpty, "history off means there is nothing to have missed")

        history = database
        reporter.report(returned: at(24, 23)...at(25, 8), now: at(25, 8))
        XCTAssertEqual(cards.map(\.body), ["1 fault"])
        XCTAssertEqual(cards.first?.source, "trill")
    }
}
