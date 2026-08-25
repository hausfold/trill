import XCTest
@testable import Trill

/// Focus-aware rules: what changes while macOS is in a Focus, and what
/// deliberately doesn't.
///
/// Three layers, all headless. The store's *shape* (a JSON file Apple writes),
/// the decision (`PolicyEngine`, pure), and the ledge door the decision opens
/// (`BannerQueue.park`). Nothing here reads a real Mac — the one thing these
/// tests cannot prove is that Apple still writes the file this way, which is
/// exactly why an unreadable or unrecognised store is a *verdict* and not a
/// crash.
final class FocusRulesTests: XCTestCase {
    private func event(
        kind: NotificationEvent.Kind = .note,
        urgency: NotificationEvent.Urgency = .normal,
        source: String = "test"
    ) -> NotificationEvent {
        NotificationEvent(source: source, title: "hello", kind: kind, urgency: urgency)
    }

    private func date(hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
    }

    private let workFocus = SystemFocus.on(FocusMode(identifier: "com.apple.focus.work", name: "Work"))

    // MARK: - Reading the store

    /// The everyday reading, in the shape the file actually has with nothing
    /// asserted (measured, same session): the `storeAssertionRecords` key is
    /// **absent** rather than empty, plus a long history of
    /// `storeInvalidationRecords` from every Focus ever ended. A reader that
    /// walked the second list would report a Focus from March.
    func testNoActiveAssertionIsOffAndNotUnknown() {
        let json = Data("""
        {"data":[{"storeInvalidationRecords":[
          {"invalidationAssertion":{"assertionUUID":"A",
            "assertionDetails":{"assertionDetailsModeIdentifier":"com.apple.focus.work"}},
           "invalidationReason":"user-changed-state"}
        ]}],"header":{"version":8}}
        """.utf8)

        XCTAssertEqual(FocusStore.evaluate(assertions: json, modeConfigurations: nil), .off)
    }

    /// The shape a live Focus actually writes, measured on macOS 26.6 on
    /// 2026-08-25 with Do Not Disturb on: one record under
    /// `storeAssertionRecords`, identified by
    /// `assertionDetails.assertionDetailsModeIdentifier`.
    func testAnActiveAssertionIsTheFocusThatIsOn() {
        let json = Data("""
        {"data":[{"storeAssertionRecords":[
          {"assertionUUID":"B","assertionStartDateTimestamp":809357041.5,
           "assertionSource":{"assertionClientIdentifier":"com.apple.controlcenter.dnd"},
           "assertionDetails":{"assertionDetailsIdentifier":"com.apple.controlcenter.dnd",
             "assertionDetailsModeIdentifier":"com.apple.donotdisturb.mode.default"}}
        ]}]}
        """.utf8)

        XCTAssertEqual(
            FocusStore.evaluate(assertions: json, modeConfigurations: nil),
            .on(FocusMode(identifier: "com.apple.donotdisturb.mode.default", name: nil))
        )
    }

    /// The second file only ever supplies a label. A Focus trill can see but
    /// can't name is still a Focus, so the fallback is a readable last
    /// component and never an empty string.
    func testTheModeConfigurationsFileNamesTheFocus() {
        let assertions = Data("""
        {"data":[{"storeAssertionRecords":[{"assertionDetails":
          {"assertionDetailsModeIdentifier":"com.apple.focus.reduce-interruptions"}}]}]}
        """.utf8)
        let modes = Data("""
        {"data":[{"modeConfigurations":{"com.apple.focus.reduce-interruptions":
          {"mode":{"name":"Reduce Interruptions","modeIdentifier":"com.apple.focus.reduce-interruptions"}}}}]}
        """.utf8)

        XCTAssertEqual(
            FocusStore.evaluate(assertions: assertions, modeConfigurations: modes).mode?.name,
            "Reduce Interruptions"
        )
        XCTAssertEqual(
            FocusStore.evaluate(assertions: assertions, modeConfigurations: nil).mode?.label,
            "Reduce Interruptions",
            "and with no names file the identifier's own tail still reads as a name"
        )
    }

    func testTheTwoModesNobodyRenamesHaveNamesWithoutTheSecondFile() {
        XCTAssertEqual(
            FocusMode(identifier: "com.apple.donotdisturb.mode.default", name: nil).label,
            "Do Not Disturb"
        )
        XCTAssertEqual(
            FocusMode(identifier: "com.apple.sleep.sleep-mode", name: nil).label, "Sleep"
        )
    }

    /// A store that isn't in the shape trill knows is "can't tell", and
    /// "can't tell" behaves as *off* everywhere a decision is made. The
    /// alternative — silencing someone's chats because a file changed shape
    /// on a macOS update — is the failure this case exists to prevent.
    func testAnUnrecognisedStoreIsCantTellAndFailsOpen() {
        let drifted = FocusStore.evaluate(assertions: Data("{}".utf8), modeConfigurations: nil)
        guard case .unknown = drifted else { return XCTFail("expected can't-tell, got \(drifted)") }
        XCTAssertFalse(drifted.isOn, "can't tell is never treated as a Focus being on")
        XCTAssertNotNil(drifted.reason, "and it says so rather than going quiet about it")

        let engine = PolicyEngine(ruleSet: .empty)
        XCTAssertEqual(
            engine.decide(event(kind: .chat), now: .now, focus: drifted),
            .banner(.primary),
            "an unreadable store decides exactly what no Focus decides"
        )
    }

    // MARK: - The three behaviors

    func testChatsMuteDuringAFocus() {
        let engine = PolicyEngine(ruleSet: .empty)
        XCTAssertEqual(engine.decide(event(kind: .chat), now: .now, focus: .off), .banner(.primary))
        XCTAssertEqual(engine.decide(event(kind: .chat), now: .now, focus: workFocus), .inboxOnly)
    }

    func testFaultsAlwaysLand() {
        let engine = PolicyEngine(ruleSet: .empty)
        XCTAssertEqual(
            engine.decide(event(kind: .fault), now: .now, focus: workFocus),
            .banner(.primary),
            "a Focus is not a reason to hide that something broke"
        )
    }

    func testAsksGoStraightToTheLedge() {
        let engine = PolicyEngine(ruleSet: .empty)
        XCTAssertEqual(
            engine.decide(event(kind: .ask), now: .now, focus: workFocus),
            .ledge(.primary),
            "a question parks rather than interrupting — and rather than vanishing"
        )
    }

    /// Everything else quietens. The default is `inbox` and not `banner`
    /// because a Focus is the user saying "not now" about the whole Mac.
    func testEverythingElseQuietens() {
        let engine = PolicyEngine(ruleSet: .empty)
        for kind: NotificationEvent.Kind in [.note, .pulse, .done] {
            XCTAssertEqual(
                engine.decide(event(kind: kind), now: .now, focus: workFocus), .inboxOnly,
                "\(kind.rawValue) should quieten during a Focus"
            )
        }
    }

    // MARK: - What a Focus may not do

    func testCriticalPunchesThroughAFocusTheWayItPunchesThroughQuietHours() {
        let engine = PolicyEngine(ruleSet: .empty)
        XCTAssertEqual(
            engine.decide(event(kind: .chat, urgency: .critical), now: .now, focus: workFocus),
            .banner(.primary)
        )
    }

    /// A Focus only ever quietens something that was going to be drawn. A
    /// rule that already said "quiet" said it about every hour of the day, so
    /// nothing here can make a digest or an inbox rule louder — or resurrect
    /// a dropped event.
    func testAFocusNeverMakesAQuietRuleLouder() {
        let engine = PolicyEngine(ruleSet: RuleSet(rules: [
            .init(match: .init(source: "ci"), delivery: .digest("work")),
            .init(match: .init(source: "ads"), delivery: .drop),
            .init(match: .init(source: "bot"), delivery: .inbox),
        ], quietHours: nil))

        XCTAssertEqual(engine.decide(event(kind: .fault, source: "ci"), now: .now, focus: workFocus), .digest("work"))
        XCTAssertEqual(engine.decide(event(kind: .fault, source: "ads"), now: .now, focus: workFocus), .drop)
        XCTAssertEqual(engine.decide(event(kind: .ask, source: "bot"), now: .now, focus: workFocus), .inboxOnly)
    }

    /// Quiet hours are the stricter signal and have the last word. "22:00 to
    /// 07:00, nothing on this screen" means the fin too.
    func testQuietHoursOverrideWhatAFocusDecided() {
        let engine = PolicyEngine(ruleSet: RuleSet(
            rules: [], quietHours: .init(startMinute: 22 * 60, endMinute: 7 * 60)
        ))

        XCTAssertEqual(engine.decide(event(kind: .ask), now: date(hour: 23), focus: workFocus), .inboxOnly)
        XCTAssertEqual(engine.decide(event(kind: .fault), now: date(hour: 23), focus: workFocus), .inboxOnly)
        XCTAssertEqual(
            engine.decide(event(kind: .ask), now: date(hour: 12), focus: workFocus), .ledge(.primary),
            "outside the window the Focus decision stands"
        )
    }

    /// The rule's display survives the detour: an ask a rule routed to the
    /// big screen parks on the big screen's ledge, not the laptop's.
    func testARoutedAskParksOnTheScreenItsRuleNamed() {
        let engine = PolicyEngine(ruleSet: RuleSet(rules: [
            .init(match: .init(kind: .ask), delivery: .banner, display: .builtin),
        ], quietHours: nil))

        XCTAssertEqual(engine.decide(event(kind: .ask), now: .now, focus: workFocus), .ledge(.builtin))
    }

    /// The ledge holds questions. A user who writes `"note": "ledge"` gets
    /// the honest nearest thing rather than a fin with nothing to press.
    func testOnlyAnAskMayBeParkedHoweverTheRulesAreWritten() {
        let engine = PolicyEngine(ruleSet: RuleSet(
            rules: [], quietHours: nil,
            focus: .init(fallback: .ledge, kinds: [:])
        ))

        XCTAssertEqual(engine.decide(event(kind: .ask), now: .now, focus: workFocus), .ledge(.primary))
        XCTAssertEqual(engine.decide(event(kind: .note), now: .now, focus: workFocus), .inboxOnly)
    }

    // MARK: - The rules file

    /// Writing the one line you care about must not silently drop the rest of
    /// the policy — the same promise `config.json` makes.
    func testAPartialFocusBlockLayersOverTheDefaults() throws {
        let json = Data(#"{"rules":[],"focus":{"chat":"banner"}}"#.utf8)
        let decoded = try JSONDecoder.trill.decode(RuleSet.self, from: json)
        let engine = PolicyEngine(ruleSet: decoded)

        XCTAssertEqual(engine.decide(event(kind: .chat), now: .now, focus: workFocus), .banner(.primary))
        XCTAssertEqual(
            engine.decide(event(kind: .fault), now: .now, focus: workFocus), .banner(.primary),
            "faults still land — naming one kind must not clear the others"
        )
        XCTAssertEqual(
            engine.decide(event(kind: .ask), now: .now, focus: workFocus), .ledge(.primary),
            "and asks still park"
        )
    }

    func testTheFocusBlockTheREADMEDocumentsDecodes() throws {
        let json = Data("""
        {
          "rules": [],
          "focus": { "default": "inbox", "fault": "banner", "ask": "ledge", "done": "banner" }
        }
        """.utf8)

        let policy = try XCTUnwrap(JSONDecoder.trill.decode(RuleSet.self, from: json).focus)
        XCTAssertEqual(policy.behavior(for: .note), .inbox)
        XCTAssertEqual(policy.behavior(for: .fault), .banner)
        XCTAssertEqual(policy.behavior(for: .ask), .ledge)
        XCTAssertEqual(policy.behavior(for: .done), .banner)
    }

    /// A typo'd kind takes the file down loudly rather than being ignored —
    /// `RulesWatcher` keeps the last good set and logs why. A silently
    /// dropped `"faults"` would be a Focus swallowing exactly what the user
    /// wrote the line to protect.
    func testAnUnknownKindIsARejectedFileNotASilentDrop() {
        let json = Data(#"{"rules":[],"focus":{"faults":"banner"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder.trill.decode(RuleSet.self, from: json))
    }

    func testAFocusPolicyRoundTripsThroughJSON() throws {
        let original = RuleSet(
            rules: [], quietHours: nil,
            focus: .init(fallback: .banner, kinds: [.chat: .inbox, .ask: .ledge])
        )
        let decoded = try JSONDecoder.trill.decode(
            RuleSet.self, from: try JSONEncoder.trill.encode(original)
        )
        XCTAssertEqual(decoded, original)
    }

    // MARK: - The ledge door

    @MainActor
    func testParkingDrawsNoBannerAndStillAnswersTheAsker() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        var parkedRounds: [[String]] = []
        queue.onParkedForResolution = { parkedRounds.append($0.map(\.id)) }

        queue.park(NotificationEvent(id: "q1", source: "lane", title: "deploy?", kind: .ask))

        XCTAssertTrue(queue.visible.isEmpty, "a Focus means the question never interrupted")
        XCTAssertEqual(queue.parked.map(\.id), ["q1"])
        XCTAssertEqual(
            parkedRounds.last, ["q1"],
            "the ledge store and any --until poller learn about it like any other fin"
        )
    }

    /// The same rule an arrival follows: a question re-asked is one question.
    @MainActor
    func testAReAskedQuestionSupersedesItsOwnFin() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue.park(NotificationEvent(id: "a", source: "lane", key: "pr-142", title: "review?", kind: .ask))
        queue.park(NotificationEvent(id: "b", source: "lane", key: "pr-142", title: "review?", kind: .ask))

        XCTAssertEqual(queue.parked.map(\.id), ["b"], "one question, one fin")
    }

    @MainActor
    func testASixthParkedQuestionEvictsTheOldestAndUnblocksIt() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        var dropped: [String] = []
        queue.onDropped = { dropped.append(contentsOf: $0.map(\.id)) }

        for i in 1...(BannerQueue.parkedCapacity + 1) {
            queue.park(NotificationEvent(id: "\(i)", source: "lane", title: "q\(i)", kind: .ask))
        }

        XCTAssertEqual(queue.parked.map(\.id), ["2", "3", "4", "5", "6"])
        XCTAssertEqual(
            dropped, ["1"],
            "an evicted question owes its blocked caller an exit code, same as off a banner"
        )
    }

    /// Belt and braces on the ledge's contract: `PolicyEngine` already
    /// coerces, and this refuses again rather than trusting it.
    @MainActor
    func testParkingAnythingButAQuestionDrawsItInstead() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue.park(NotificationEvent(id: "n", source: "s", title: "note", kind: .note))

        XCTAssertTrue(queue.parked.isEmpty)
        XCTAssertEqual(queue.visible.map(\.id), ["n"])
    }

    // MARK: - What the inbox is told

    /// A fin is not a banner. It is on the *edge* of the screen, waiting on
    /// somebody — so it lands unread, which is what the inbox's count and the
    /// catch-up card's tally both mean by the word.
    func testAParkedQuestionIsRecordedUnread() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("focus-\(UUID().uuidString)")
            .appendingPathComponent("trill.db")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let database = try XCTUnwrap(AppDatabase(url: file))

        let ask = NotificationEvent(id: "q", source: "lane", title: "deploy?", kind: .ask)
        database.insert(ask, decision: .ledge(.primary), seen: true)

        let row = try XCTUnwrap(database.recent(limit: 10).first)
        XCTAssertEqual(row.decision, "ledge", "its own label, not a banner's")
        XCTAssertNil(row.readAt, "trill deliberately did not put this in front of anyone")
    }
}
