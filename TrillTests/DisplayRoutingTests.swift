import XCTest
@testable import Trill

/// Per-display routing: the rules key, what a target resolves to, and how the
/// queue counts one column per screen.
final class DisplayRoutingTests: XCTestCase {
    private let laptop = ScreenDescriptor(
        id: "laptop",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944),
        isBuiltin: true
    )
    private let monitor = ScreenDescriptor(
        id: "monitor",
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415)
    )

    private func event(
        _ id: String,
        kind: NotificationEvent.Kind = .note,
        urgency: NotificationEvent.Urgency = .normal
    ) -> NotificationEvent {
        NotificationEvent(id: id, source: "test", title: id, kind: kind, urgency: urgency)
    }

    // MARK: - Resolving a target against real displays

    func testTargetsResolveAgainstTheAttachedDisplays() {
        let screens = [laptop, monitor]
        XCTAssertEqual(
            DisplayRouter.screen(for: .primary, among: screens, pointer: "monitor")?.id,
            "laptop",
            "primary is the menu-bar display whatever the pointer is doing"
        )
        XCTAssertEqual(
            DisplayRouter.screen(for: .active, among: screens, pointer: "monitor")?.id,
            "monitor"
        )
        XCTAssertEqual(
            DisplayRouter.screen(for: .builtin, among: screens, pointer: "monitor")?.id,
            "laptop"
        )
        XCTAssertEqual(
            DisplayRouter.screen(for: .external, among: screens, pointer: nil)?.id,
            "monitor"
        )
    }

    func testEveryTargetFallsBackToPrimaryRatherThanNowhere() {
        // The monitor got unplugged, the pointer is off in nobody's frame.
        let screens = [laptop]
        for target in DisplayTarget.allCases {
            XCTAssertEqual(
                DisplayRouter.screen(for: target, among: screens, pointer: "gone")?.id,
                "laptop",
                "\(target) must still land somewhere — routing moves a banner, never loses one"
            )
        }
        XCTAssertNil(
            DisplayRouter.screen(for: .primary, among: [], pointer: nil),
            "with no displays at all there is nowhere to fall back to"
        )
    }

    func testTwoTargetsOnOneScreenShareThatScreensCapacity() {
        // A laptop with nothing plugged in: every target is the same display,
        // so the column must be counted once, not four times.
        let routing = DisplayRouter.routing(among: [laptop], pointer: "laptop")
        XCTAssertEqual(Set(routing.screens.values), ["laptop"])
        XCTAssertEqual(routing.capacity.count, 1)
        XCTAssertEqual(routing.capacity["laptop"], BannerGeometry.capacity(on: laptop))
    }

    func testUnknownScreenFitsNothing() {
        let routing = DisplayRouter.routing(among: [laptop], pointer: nil)
        XCTAssertEqual(routing.capacity(of: "monitor"), 0)
        XCTAssertEqual(routing.capacity(of: nil), 0)
    }

    // MARK: - The rules key

    func testDisplayIsReadFlatBesideDelivery() throws {
        let json = """
        { "rules": [
            { "match": { "kind": "chat" }, "delivery": "banner", "display": "builtin" },
            { "match": { "kind": "fault" }, "display": "active" },
            { "match": { "source": "ads" }, "delivery": "drop" }
        ] }
        """
        let rules = try JSONDecoder.trill.decode(RuleSet.self, from: Data(json.utf8))

        XCTAssertEqual(rules.rules[0].display, .builtin)
        XCTAssertEqual(rules.rules[0].delivery, .banner)
        XCTAssertEqual(
            rules.rules[1].delivery, .banner,
            "a rule that names only a display is a routing rule; it banners"
        )
        XCTAssertEqual(rules.rules[1].display, .active)
        XCTAssertNil(rules.rules[2].display)
    }

    func testARuleWithNeitherDeliveryNorDisplayStillFailsLoudly() {
        let json = """
        { "rules": [ { "match": { "source": "ads" }, "delivry": "drop" } ] }
        """
        XCTAssertThrowsError(
            try JSONDecoder.trill.decode(RuleSet.self, from: Data(json.utf8)),
            "a mistyped delivery key must not quietly become a banner rule"
        )
    }

    func testDisplayRoundTripsThroughTheDocumentedShape() throws {
        let rule = RuleSet.Rule(
            match: .init(kind: .fault), delivery: .banner, display: .external
        )
        let data = try JSONEncoder().encode(RuleSet(rules: [rule], quietHours: nil))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let encoded = try XCTUnwrap((object["rules"] as? [[String: Any]])?.first)
        XCTAssertEqual(encoded["display"] as? String, "external")
        XCTAssertEqual(encoded["delivery"] as? String, "banner")
        XCTAssertEqual(
            try JSONDecoder.trill.decode(RuleSet.self, from: data).rules, [rule]
        )
    }

    func testKindMatchesExactly() {
        let match = RuleSet.Rule.Match(kind: .fault)
        XCTAssertTrue(match.matches(event("a", kind: .fault)))
        XCTAssertFalse(match.matches(event("b", kind: .chat)))
    }

    // MARK: - The policy engine's answer

    func testTheMatchingRuleDecidesTheDisplay() {
        let engine = PolicyEngine(ruleSet: RuleSet(rules: [
            .init(match: .init(kind: .chat), delivery: .banner, display: .builtin),
            .init(match: .init(kind: .fault), delivery: .banner, display: .active),
        ], quietHours: nil))

        XCTAssertEqual(engine.decide(event("a", kind: .chat), now: .now), .banner(.builtin))
        XCTAssertEqual(engine.decide(event("b", kind: .fault), now: .now), .banner(.active))
        XCTAssertEqual(
            engine.decide(event("c", kind: .note), now: .now), .banner(.primary),
            "an unrouted event goes where macOS puts its own"
        )
    }

    func testQuietHoursStillDemoteARoutedBanner() {
        let engine = PolicyEngine(ruleSet: RuleSet(
            rules: [.init(match: .init(), delivery: .banner, display: .external)],
            quietHours: .init(startMinute: 0, endMinute: 1440 - 1)
        ))
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
        XCTAssertEqual(
            engine.decide(event("a"), now: noon), .inboxOnly,
            "naming a display must not buy an event past quiet hours"
        )
    }

    // MARK: - The queue's columns

    /// Two displays of one card each, so overflow is easy to provoke.
    @MainActor
    private func twoScreenQueue() -> BannerQueue {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600), coalesceWindow: 0)
        queue.displays = {
            DisplayRouting(
                screens: [.primary: "laptop", .builtin: "laptop", .active: "monitor", .external: "monitor"],
                capacity: ["laptop": 1, "monitor": 1]
            )
        }
        queue.refreshDisplays()
        return queue
    }

    @MainActor
    func testEachDisplayHasItsOwnColumn() {
        let queue = twoScreenQueue()
        queue.enqueue(event("chat"), on: .builtin)
        queue.enqueue(event("fault"), on: .active)

        XCTAssertEqual(queue.visible.count, 2, "one card per display, neither waiting")
        XCTAssertEqual(queue.visible.map(\.screenID), ["laptop", "monitor"])
    }

    @MainActor
    func testAFullDisplayDoesNotHoldUpAnother() {
        let queue = twoScreenQueue()
        queue.enqueue(event("laptop 1"), on: .builtin)
        queue.enqueue(event("laptop 2"), on: .builtin)   // waits: the laptop is full
        queue.enqueue(event("monitor 1"), on: .active)   // must not queue behind it

        XCTAssertEqual(queue.visible.map(\.event.title), ["laptop 1", "monitor 1"])
        XCTAssertEqual(queue.waitingCount(onScreen: "laptop"), 1)
        XCTAssertEqual(queue.waitingCount(onScreen: "monitor"), 0)

        queue.dismiss(id: "laptop 1")
        XCTAssertEqual(
            queue.visible.map(\.event.title), ["monitor 1", "laptop 2"],
            "the freed slot refills from that display's own line"
        )
    }

    @MainActor
    func testTwoTargetsOnOneDisplayShareItsRoom() {
        // The single-display case, written as two different rules: without
        // per-screen counting this draws two overlapping columns.
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600), coalesceWindow: 0)
        queue.enqueue(event("a"), on: .builtin)
        queue.enqueue(event("b"), on: .active)

        XCTAssertEqual(queue.visible.count, 1)
        XCTAssertEqual(queue.waitingCount, 1)
    }

    @MainActor
    func testTheDisplayIsFrozenAtArrivalButReResolvedOnRebuild() {
        let queue = twoScreenQueue()
        queue.enqueue(event("fault"), on: .active)
        XCTAssertEqual(queue.visible[0].screenID, "monitor")

        // The pointer moves to the laptop. Nothing re-resolves until the
        // topology itself changes — a card that hops screens under you is a
        // card you lose.
        queue.displays = {
            DisplayRouting(
                screens: [.primary: "laptop", .builtin: "laptop", .active: "laptop", .external: "laptop"],
                capacity: ["laptop": 2]
            )
        }
        queue.enqueue(event("note"), on: .primary)
        XCTAssertEqual(
            queue.visible.map(\.screenID), ["monitor", "laptop"],
            "the standing card kept the screen it landed on"
        )

        queue.refreshDisplays()
        XCTAssertEqual(
            queue.visible.map(\.screenID), ["laptop", "laptop"],
            "unplugging the monitor moves its cards rather than stranding them"
        )
    }

    @MainActor
    func testUnpluggingADisplayQueuesItsCardsRatherThanDroppingThem() {
        let queue = twoScreenQueue()
        queue.enqueue(event("laptop"), on: .builtin)
        queue.enqueue(event("monitor"), on: .active)

        // Only the laptop is left, and it fits one card.
        queue.setCapacity(1)
        XCTAssertEqual(queue.visible.count, 1)
        XCTAssertEqual(queue.waitingCount, 1, "no event was lost to the rebuild")

        queue.dismiss(id: queue.visible[0].id)
        XCTAssertEqual(queue.visible.count, 1, "and it comes back on the display that is left")
    }

    @MainActor
    func testAnEventForANoLongerAttachedDisplayWaits() {
        let queue = twoScreenQueue()
        queue.displays = {
            DisplayRouting(screens: [.primary: "laptop"], capacity: ["laptop": 1])
        }
        queue.refreshDisplays()

        queue.enqueue(event("stranded"), on: .external)
        XCTAssertTrue(queue.visible.isEmpty, "no screen, no panel")
        XCTAssertEqual(queue.waitingCount, 1, "…and no loss either")
    }

    @MainActor
    func testHoverPausesOnlyTheDisplayItHappenedOn() async throws {
        let queue = BannerQueue(capacity: 1, displayDuration: .milliseconds(80), coalesceWindow: 0)
        queue.displays = {
            DisplayRouting(
                screens: [.primary: "laptop", .builtin: "laptop", .active: "monitor", .external: "monitor"],
                capacity: ["laptop": 1, "monitor": 1]
            )
        }
        queue.refreshDisplays()
        queue.enqueue(event("held"), on: .builtin)
        queue.enqueue(event("ticking"), on: .active)

        queue.setHover(true, id: "held")
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertEqual(
            queue.visible.map(\.event.title), ["held"],
            "the card under the pointer stays; the one on the other display keeps its clock"
        )
    }
}
