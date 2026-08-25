import XCTest
@testable import Trill

/// The calendar source, headless: which occurrences earn a banner, when it is
/// owed, what it says, and which links are honestly called "Join". Everything
/// EventKit-shaped stops at `CalendarProvider`, so none of this needs a store,
/// a grant, or a meeting.
final class CalendarSourceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func occurrence(
        identifier: String = "abc",
        externalIdentifier: String? = "EXT-abc",
        title: String = "Standup",
        isAllDay: Bool = false,
        isCancelled: Bool = false,
        isDeclined: Bool = false,
        location: String? = nil,
        notes: String? = nil,
        url: URL? = nil
    ) -> CalendarOccurrence {
        CalendarOccurrence(
            identifier: identifier,
            externalIdentifier: externalIdentifier,
            title: title,
            start: start,
            isAllDay: isAllDay,
            isCancelled: isCancelled,
            isDeclined: isDeclined,
            calendarTitle: "Work",
            location: location,
            notes: notes,
            url: url
        )
    }

    // MARK: - What earns a banner

    func testAllDayCancelledAndDeclinedOccurrencesNeverBanner() {
        XCTAssertTrue(CalendarEventMapper.remindable(occurrence()))
        XCTAssertFalse(CalendarEventMapper.remindable(occurrence(isAllDay: true)), "a birthday is not a meeting")
        XCTAssertFalse(CalendarEventMapper.remindable(occurrence(isCancelled: true)))
        XCTAssertFalse(
            CalendarEventMapper.remindable(occurrence(isDeclined: true)),
            "trill doesn't nag you about a meeting you said no to"
        )
    }

    func testDueIsAboutTheFireDateNotTheWindow() {
        let lead: TimeInterval = 600
        let occurrence = occurrence()
        XCTAssertEqual(CalendarEventMapper.fireDate(for: occurrence, leadTime: lead), start - 600)
        XCTAssertFalse(CalendarEventMapper.isDue(occurrence, leadTime: lead, now: start - 601))
        XCTAssertTrue(CalendarEventMapper.isDue(occurrence, leadTime: lead, now: start - 600))
        // Missed across a sleep: still owed, not expired. Whether the meeting
        // has since started is the watcher's call, not this one's.
        XCTAssertTrue(CalendarEventMapper.isDue(occurrence, leadTime: lead, now: start - 60))
    }

    // MARK: - Words

    func testLeadPhraseSaysWhatIsTrueNotWhatWasScheduled() {
        XCTAssertEqual(CalendarEventMapper.leadPhrase(start: start, now: start - 600), "in 10m")
        // A timer that fired 20 seconds late still reads "in 10m" — rounding,
        // not truncation, is what keeps the banner honest about the lead.
        XCTAssertEqual(CalendarEventMapper.leadPhrase(start: start, now: start - 580), "in 10m")
        XCTAssertEqual(CalendarEventMapper.leadPhrase(start: start, now: start - 5_400), "in 1h 30m")
        XCTAssertEqual(CalendarEventMapper.leadPhrase(start: start, now: start - 7_200), "in 2h")
        XCTAssertEqual(CalendarEventMapper.leadPhrase(start: start, now: start - 10), "starting now")
        XCTAssertEqual(CalendarEventMapper.leadPhrase(start: start, now: start + 30), "starting now")
    }

    func testSubtitleLeadsWithTheCountdownAndAnchorsItToAClock() {
        let subtitle = CalendarEventMapper.subtitle(for: occurrence(), now: start - 600)
        XCTAssertTrue(subtitle.hasPrefix("in 10m · "), subtitle)
        XCTAssertGreaterThan(subtitle.count, "in 10m · ".count, "the clock time is the anchor")
    }

    // MARK: - The Join pill

    func testConferencingHostsMatchSubdomainsAndNothingElse() {
        XCTAssertTrue(CalendarEventMapper.isConferencing(URL(string: "https://us02web.zoom.us/j/123")!))
        XCTAssertTrue(CalendarEventMapper.isConferencing(URL(string: "https://meet.google.com/abc-defg-hij")!))
        XCTAssertTrue(CalendarEventMapper.isConferencing(URL(string: "https://acme.webex.com/meet/x")!))
        // The dot is load-bearing: a suffix match without it makes every
        // look-alike domain a meeting.
        XCTAssertFalse(CalendarEventMapper.isConferencing(URL(string: "https://notzoom.us/j/123")!))
        XCTAssertFalse(CalendarEventMapper.isConferencing(URL(string: "https://example.com/agenda")!))
        XCTAssertFalse(CalendarEventMapper.isConferencing(URL(string: "ftp://zoom.us/j/1")!))
    }

    func testMeetingURLPrefersTheEventsOwnFieldThenLocationThenNotes() {
        let field = URL(string: "https://meet.google.com/from-url")!
        XCTAssertEqual(
            CalendarEventMapper.meetingURL(in: occurrence(
                location: "https://us02web.zoom.us/j/from-location", url: field
            )),
            field
        )
        XCTAssertEqual(
            CalendarEventMapper.meetingURL(in: occurrence(location: "https://us02web.zoom.us/j/9"))?.absoluteString,
            "https://us02web.zoom.us/j/9"
        )
        XCTAssertEqual(
            CalendarEventMapper.meetingURL(in: occurrence(
                notes: "Agenda: https://example.com/doc\nJoin: https://meet.jit.si/trill"
            ))?.absoluteString,
            "https://meet.jit.si/trill",
            "the first link in the notes is usually a doc — only a known host is a Join"
        )
    }

    func testNoRecognizedLinkMeansNoJoinPill() {
        XCTAssertNil(CalendarEventMapper.meetingURL(in: occurrence(
            location: "Room 3", notes: "Spec: https://example.com/spec"
        )))
        let event = CalendarEventMapper.event(
            for: occurrence(location: "Room 3", notes: "Spec: https://example.com/spec"),
            now: start - 600
        )
        XCTAssertEqual(event.actions.map(\.label), ["Open"])
        XCTAssertTrue(event.pillActions.isEmpty, "a lone action rides the meta row, not a pill")
    }

    // MARK: - The banner

    func testMeetingWithALinkDrawsOpenThenJoin() {
        let event = CalendarEventMapper.event(
            for: occurrence(url: URL(string: "https://us02web.zoom.us/j/42")!),
            now: start - 600
        )
        XCTAssertEqual(event.source, CalendarEventMapper.source)
        XCTAssertEqual(event.id, "cal:abc")
        XCTAssertEqual(event.title, "Standup")
        XCTAssertEqual(event.kind, .note, "an ask would park on the ledge forever — nothing answers a meeting")
        XCTAssertTrue(event.subtitle?.hasPrefix("in 10m") == true)
        XCTAssertEqual(event.symbol, "video.fill")
        XCTAssertEqual(event.actions.map(\.label), ["Open", "Join"])
        XCTAssertEqual(event.actions.first?.kind, .openEvent)
        XCTAssertEqual(event.actions.first?.target, "EXT-abc")
        XCTAssertEqual(event.actions.last?.kind, .openURL)
        XCTAssertEqual(event.pillActions.count, 2, "both are performable, so both are drawn")
        XCTAssertEqual(event.metadata["calendar"], "Work")
        // The card click runs the first action only, and that one opens the
        // event rather than joining the call.
        XCTAssertTrue(event.hasDefaultAction)
    }

    func testOpenFallsBackToCalendarWhenTheStorePublishesNoExternalID() {
        let event = CalendarEventMapper.event(for: occurrence(externalIdentifier: nil), now: start - 600)
        XCTAssertEqual(event.actions.first?.kind, .openApp)
        XCTAssertEqual(event.actions.first?.target, CalendarEventMapper.calendarBundleID)
        XCTAssertTrue(event.actions.first?.isPerformable == true, "trill draws no dead buttons")
    }

    func testLocationRidesTheBodyUnlessItIsAlreadyTheJoinLink() {
        let room = CalendarEventMapper.event(for: occurrence(location: "Room 3"), now: start - 600)
        XCTAssertEqual(room.body, "Room 3")

        let link = "https://meet.google.com/abc-defg-hij"
        let call = CalendarEventMapper.event(for: occurrence(location: link), now: start - 600)
        XCTAssertNil(call.body, "the Join pill already carries it")
        XCTAssertEqual(call.metadata["location"], link, "still recorded, just not drawn twice")
    }

    func testUntitledOccurrencesStillSayAndDoSomething() {
        let event = CalendarEventMapper.event(for: occurrence(title: "   "), now: start - 600)
        XCTAssertEqual(event.title, "Untitled event")
    }

    func testMovedMeetingsAreADifferentOccurrenceAndEarnAFreshBanner() {
        // The dedupe id is per-occurrence, not per-event, which is what keeps
        // a rescheduled meeting from being swallowed as a duplicate.
        let first = CalendarEventMapper.event(for: occurrence(identifier: "abc|1700000000"), now: start - 600)
        let moved = CalendarEventMapper.event(for: occurrence(identifier: "abc|1700003600"), now: start - 600)
        XCTAssertNotEqual(first.id, moved.id)
    }

    // MARK: - The action's own guard

    func testOpenEventTargetsAreCheckedTheWayLaneTargetsAre() {
        XCTAssertTrue(NotificationEvent.Action.namesCalendarEvent("EXT-abc"))
        XCTAssertTrue(NotificationEvent.Action.namesCalendarEvent("040000008200E00074C5B7101A82E008:19700101"))
        XCTAssertFalse(NotificationEvent.Action.namesCalendarEvent(nil))
        XCTAssertFalse(NotificationEvent.Action.namesCalendarEvent(""))
        XCTAssertFalse(NotificationEvent.Action.namesCalendarEvent("has\na newline"))
        XCTAssertFalse(NotificationEvent.Action.namesCalendarEvent(String(repeating: "a", count: 513)))
    }

    func testAnOlderTrillReadsOpenEventAsInertRatherThanBroken() throws {
        let wire = Data(#"{"id":"a","label":"Open","kind":"open_event","target":"EXT-abc"}"#.utf8)
        let action = try JSONDecoder().decode(NotificationEvent.Action.self, from: wire)
        XCTAssertEqual(action.kind, .openEvent)

        let future = Data(#"{"id":"a","label":"?","kind":"open_hologram","target":"x"}"#.utf8)
        let unknown = try JSONDecoder().decode(NotificationEvent.Action.self, from: future)
        XCTAssertEqual(unknown.kind, .unsupported)
        XCTAssertFalse(unknown.isPerformable)
    }

    // MARK: - The switches

    func testCalendarKeysRoundTripThroughConfigJSON() {
        var config = AppConfig()
        XCTAssertFalse(config.calendarEnabled, "reading a calendar is opt-in")
        XCTAssertEqual(config.calendarLeadMinutes, 10)

        config.calendarEnabled = true
        config.calendarLeadMinutes = 25
        let json = config.json
        XCTAssertEqual(AppConfig(json: json), config, "a switch that writes but doesn't read reverts on reload")
    }

    func testATypoedLeadIsClampedRatherThanIgnored() {
        XCTAssertEqual(AppConfig(json: ["calendarLeadMinutes": 600_000]).calendarLeadMinutes, 24 * 60)
        XCTAssertEqual(AppConfig(json: ["calendarLeadMinutes": -5]).calendarLeadMinutes, 0)
        XCTAssertEqual(AppConfig(json: ["calendarLeadMinutes": "soon"]).calendarLeadMinutes, 10)
    }

    /// The double-banner this app exists to catch: trill's meeting card and
    /// Apple's Calendar alert, ten minutes before the same meeting.
    func testCalendarJoinsTheAuditScopeOnlyWhenTheSourceIsOn() {
        let rules = RuleSet(
            rules: [.init(match: .init(source: "com.tinyspeck.slackmacgap"), delivery: .banner)],
            quietHours: nil
        )
        XCTAssertEqual(
            NotificationSettingsAudit.listedBundleIDs(in: rules),
            ["com.tinyspeck.slackmacgap"],
            "a source nobody switched on gets no say over what trill audits"
        )
        XCTAssertEqual(
            NotificationSettingsAudit.listedBundleIDs(in: rules, calendarSourceEnabled: true),
            ["com.tinyspeck.slackmacgap", CalendarEventMapper.calendarBundleID]
        )
    }

    func testLeadLabelStaysReadableAtEveryScale() {
        XCTAssertEqual(SettingsPane.leadLabel(0), "At start")
        XCTAssertEqual(SettingsPane.leadLabel(10), "10m")
        XCTAssertEqual(SettingsPane.leadLabel(60), "1h")
        XCTAssertEqual(SettingsPane.leadLabel(95), "1h 35m")
        XCTAssertEqual(SettingsPane.leadDescription(0), "just as")
        XCTAssertEqual(SettingsPane.leadDescription(10), "10m before")
    }
}
