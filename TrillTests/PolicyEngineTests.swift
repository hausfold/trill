import XCTest
@testable import Trill

final class PolicyEngineTests: XCTestCase {
    private func event(
        source: String = "test",
        title: String = "hello",
        urgency: NotificationEvent.Urgency = .normal
    ) -> NotificationEvent {
        NotificationEvent(source: source, title: title, urgency: urgency)
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        Calendar.current.date(
            bySettingHour: hour, minute: minute, second: 0, of: .now
        )!
    }

    func testNoRulesMeansBanner() {
        let engine = PolicyEngine(ruleSet: .empty)
        XCTAssertEqual(engine.decide(event(), now: .now), .banner)
    }

    func testFirstMatchingRuleWins() {
        let engine = PolicyEngine(ruleSet: RuleSet(rules: [
            .init(match: .init(source: "slack", titleContains: "mentioned"), delivery: .banner),
            .init(match: .init(source: "slack"), delivery: .digest("work")),
        ], quietHours: nil))

        XCTAssertEqual(
            engine.decide(event(source: "slack", title: "you were mentioned"), now: .now),
            .banner
        )
        XCTAssertEqual(
            engine.decide(event(source: "slack", title: "daily summary"), now: .now),
            .digest("work")
        )
        XCTAssertEqual(engine.decide(event(source: "mail"), now: .now), .banner)
    }

    func testSourceMatchIsCaseInsensitiveAgainstNormalizedEvents() {
        let engine = PolicyEngine(ruleSet: RuleSet(rules: [
            .init(match: .init(source: "Slack"), delivery: .drop),
        ], quietHours: nil))
        // Events arrive normalized (lowercased source); the rule's own case
        // must not matter.
        XCTAssertEqual(
            engine.decide(event(source: "slack").normalized(), now: .now),
            .drop
        )
    }

    func testUrgencyCeilingLimitsRule() {
        let engine = PolicyEngine(ruleSet: RuleSet(rules: [
            .init(match: .init(source: "ci", urgencyAtMost: .normal), delivery: .inbox),
        ], quietHours: nil))

        XCTAssertEqual(engine.decide(event(source: "ci"), now: .now), .inboxOnly)
        XCTAssertEqual(
            engine.decide(event(source: "ci", urgency: .critical), now: .now),
            .banner,
            "critical escapes an at-most-normal rule"
        )
    }

    func testQuietHoursDemoteBannersToInbox() {
        let engine = PolicyEngine(ruleSet: RuleSet(
            rules: [],
            quietHours: .init(startMinute: 22 * 60, endMinute: 7 * 60)
        ))

        XCTAssertEqual(engine.decide(event(), now: date(hour: 23)), .inboxOnly)
        XCTAssertEqual(engine.decide(event(), now: date(hour: 3)), .inboxOnly)
        XCTAssertEqual(engine.decide(event(), now: date(hour: 12)), .banner)
    }

    func testCriticalPunchesThroughQuietHours() {
        let engine = PolicyEngine(ruleSet: RuleSet(
            rules: [],
            quietHours: .init(startMinute: 0, endMinute: 24 * 60)
        ))
        XCTAssertEqual(
            engine.decide(event(urgency: .critical), now: date(hour: 3)),
            .banner
        )
    }

    func testQuietWindowEdges() {
        let window = RuleSet.QuietHours(startMinute: 22 * 60, endMinute: 7 * 60)
        XCTAssertTrue(window.contains(minuteOfDay: 22 * 60))
        XCTAssertFalse(window.contains(minuteOfDay: 7 * 60))
        XCTAssertTrue(window.contains(minuteOfDay: 0))
        XCTAssertFalse(window.contains(minuteOfDay: 12 * 60))
    }

    /// The shape the README documents and a human actually writes: `delivery`
    /// flat beside `match`, not nested in an object of its own. The round-trip
    /// test below can't catch a regression here — it agrees with itself
    /// whatever convention the encoder picks — and the first cut of this
    /// decoder failed every hand-written file while logging one line about it.
    func testTheRulesFileTheREADMEDocumentsActuallyDecodes() throws {
        let json = Data("""
        {
          "rules": [
            { "match": { "source": "slack", "titleContains": "mentioned" }, "delivery": "banner" },
            { "match": { "source": "slack" }, "delivery": "digest", "digest": "work" },
            { "match": { "source": "ads" }, "delivery": "drop" },
            { "match": { "source": "com.apple.reminders" }, "delivery": "inbox" }
          ]
        }
        """.utf8)

        let decoded = try JSONDecoder.trill.decode(RuleSet.self, from: json)
        XCTAssertEqual(decoded.rules.count, 4)
        XCTAssertEqual(decoded.rules[0].delivery, .banner)
        XCTAssertEqual(decoded.rules[0].match.titleContains, "mentioned")
        XCTAssertEqual(decoded.rules[1].delivery, .digest("work"))
        XCTAssertEqual(decoded.rules[2].delivery, .drop)
        XCTAssertEqual(decoded.rules[3].delivery, .inbox)
        XCTAssertEqual(decoded.rules[3].match.source, "com.apple.reminders")
    }

    /// A rule the daemon can't read must not take the rest of the file with
    /// it silently — the decode fails loudly enough for `RulesWatcher` to keep
    /// the last good set and log why.
    func testAnUnknownDeliveryIsARejectedFileNotASilentDrop() {
        let json = Data(#"{"rules":[{"match":{"source":"ads"},"delivery":"shred"}]}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder.trill.decode(RuleSet.self, from: json))
    }

    func testRuleSetRoundTripsThroughJSON() throws {
        let original = RuleSet(rules: [
            .init(match: .init(source: "slack", titleContains: "mention"), delivery: .digest("work")),
            .init(match: .init(source: "ads"), delivery: .drop),
        ], quietHours: .init(startMinute: 1320, endMinute: 420))

        let data = try JSONEncoder.trill.encode(original)
        let decoded = try JSONDecoder.trill.decode(RuleSet.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
