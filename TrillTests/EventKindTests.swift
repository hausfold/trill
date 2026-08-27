import SwiftUI
import XCTest
@testable import Trill

/// The kind system: hue-by-meaning on the event, weight staying urgency's.
/// Pure domain + queue-ordering rules — no display, no daemon.
final class EventKindTests: XCTestCase {
    // MARK: - Decoding

    func testUnkindedEventsKeepTheirOldReading() throws {
        // Old senders never wrote `kind`. Critical used to render red, so an
        // un-kinded critical becomes a fault; everything else is a note.
        let critical = Data(#"{"title":"disk", "urgency":"critical"}"#.utf8)
        XCTAssertEqual(try JSONDecoder.trill.decode(NotificationEvent.self, from: critical).kind, .fault)

        let normal = Data(#"{"title":"hello"}"#.utf8)
        XCTAssertEqual(try JSONDecoder.trill.decode(NotificationEvent.self, from: normal).kind, .note)
    }

    func testAnExplicitKindBeatsTheInference() throws {
        let chat = Data(#"{"title":"mireille", "kind":"chat", "urgency":"critical"}"#.utf8)
        XCTAssertEqual(
            try JSONDecoder.trill.decode(NotificationEvent.self, from: chat).kind, .chat,
            "a critical chat is still a chat — urgency is loudness, not meaning"
        )
    }

    func testKindRoundTripsThroughTheWire() throws {
        let event = NotificationEvent(source: "scruff", title: "lane blocked", kind: .ask)
        let data = try JSONEncoder.trill.encode(event)
        XCTAssertEqual(try JSONDecoder.trill.decode(NotificationEvent.self, from: data).kind, .ask)
    }

    func testEveryKindCarriesADefaultGlyph() {
        for kind in NotificationEvent.Kind.allCases {
            XCTAssertFalse(kind.defaultSymbol.isEmpty)
        }
    }

    // MARK: - CLI

    func testSendParsesKindAndActions() throws {
        guard case .success(let event) = TrillCLI.parseSend([
            "--title", "Lane blocked",
            "--kind", "ask",
            "--action", "Open PR=https://github.com/hausfold/trill/pull/9",
            "--action", "Open pane=app:com.mitchellh.ghostty",
        ]) else { return XCTFail("parse failed") }

        XCTAssertEqual(event.kind, .ask)
        XCTAssertEqual(event.actions.count, 2)
        XCTAssertEqual(event.actions[0].label, "Open PR")
        XCTAssertEqual(event.actions[0].kind, .openURL)
        XCTAssertEqual(event.actions[1].kind, .openApp)
        XCTAssertEqual(event.actions[1].target, "com.mitchellh.ghostty")
    }

    func testSendRefusesAKindItDoesNotKnow() {
        if case .success = TrillCLI.parseSend(["--title", "x", "--kind", "loud"]) {
            XCTFail("bad kind must fail")
        }
    }

    func testSendRefusesAnActionWithoutALabelOrOpenableTarget() {
        if case .success = TrillCLI.parseSend(["--title", "x", "--action", "nope"]) {
            XCTFail("--action without = must fail")
        }
        if case .success = TrillCLI.parseSend(["--title", "x", "--action", "Run=javascript:alert(1)"]) {
            XCTFail("a scheme the router would refuse must be refused at parse")
        }
    }

    func testAnUnlabeledCriticalSendIsAFault() throws {
        guard case .success(let event) = TrillCLI.parseSend([
            "--title", "disk", "--urgency", "critical",
        ]) else { return XCTFail("parse failed") }
        XCTAssertEqual(event.kind, .fault)
    }

    // MARK: - Pills

    func testPillActionsDrawOnlyPluralPerformableActions() {
        let url = NotificationEvent.Action(id: "a", label: "Open", kind: .openURL, target: "https://x.dev")
        let app = NotificationEvent.Action(id: "b", label: "App", kind: .openApp, target: "com.x.y")
        let dead = NotificationEvent.Action(id: "c", label: "Hook", kind: .command, target: "retry")

        XCTAssertTrue(
            NotificationEvent(source: "s", title: "t", actions: [url]).pillActions.isEmpty,
            "a single action is the inline label, not a pill row"
        )
        XCTAssertEqual(
            NotificationEvent(source: "s", title: "t", actions: [url, app]).pillActions.count, 2
        )
        XCTAssertEqual(
            NotificationEvent(source: "s", title: "t", actions: [url, dead, app]).pillActions.count, 2,
            "an inert command action never becomes a pill — trill draws no dead buttons"
        )
        XCTAssertEqual(
            NotificationEvent(source: "s", title: "t", actions: [url, app, url, app]).pillActions.count,
            NotificationEvent.Limits.drawnActions
        )
    }

    // MARK: - Theme

    func testThemeParsesKindHexAndIgnoresNoise() throws {
        let data = Data(##"{"ask":"#f5b58e","fault":"ed8fa9","volume":"11","done":"nope"}"##.utf8)
        let theme = try XCTUnwrap(BannerTheme.parse(data))
        XCTAssertEqual(theme.kindColors[.ask], Color(trillHex: "#f5b58e"))
        XCTAssertEqual(theme.kindColors[.fault], Color(trillHex: "ed8fa9"))
        XCTAssertEqual(
            theme.kindColors[.done], BannerTheme.fallback.kindColors[.done],
            "a hex that doesn't parse keeps the fallback rather than dropping the kind"
        )
        XCTAssertNil(BannerTheme.parse(Data(#"["not","a","theme"]"#.utf8)))
    }

    // MARK: - Age label

    func testAgeIsCompactAndNeverNegativeSounding() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(BannerView.age(of: now, at: now), "now")
        XCTAssertEqual(BannerView.age(of: now.addingTimeInterval(-59), at: now), "now")
        XCTAssertEqual(BannerView.age(of: now.addingTimeInterval(-240), at: now), "4m")
        XCTAssertEqual(BannerView.age(of: now.addingTimeInterval(-7200), at: now), "2h")
        XCTAssertEqual(BannerView.age(of: now.addingTimeInterval(-200_000), at: now), "2d")
    }

    // MARK: - Waiting-line order

    @MainActor
    func testACriticalNeverWaitsBehindNotes() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600), coalesceWindow: 0)
        queue.enqueue(NotificationEvent(source: "a", title: "visible"))
        queue.enqueue(NotificationEvent(source: "b", title: "note 1"))
        queue.enqueue(NotificationEvent(source: "c", title: "note 2"))
        queue.enqueue(NotificationEvent(source: "d", title: "disk", urgency: .critical))
        queue.enqueue(NotificationEvent(source: "e", title: "note 3"))

        XCTAssertEqual(queue.waitingCount, 4)
        queue.dismiss(id: queue.visible[0].id)
        XCTAssertEqual(
            queue.visible[0].event.title, "disk",
            "the freed slot goes to the critical, not to the note that arrived first"
        )
        queue.dismiss(id: queue.visible[0].id)
        XCTAssertEqual(
            queue.visible[0].event.title, "note 1",
            "within a rank, arrival order holds"
        )
    }

    @MainActor
    func testShrinkingTheDisplayPutsOverflowBackBeforeItsOwnRank() {
        let queue = BannerQueue(capacity: 2, displayDuration: .seconds(3600), coalesceWindow: 0)
        queue.enqueue(NotificationEvent(source: "a", title: "one"))
        queue.enqueue(NotificationEvent(source: "b", title: "two"))
        queue.enqueue(NotificationEvent(source: "c", title: "three"))
        XCTAssertEqual(queue.waitingCount, 1)

        queue.setCapacity(1)
        XCTAssertEqual(queue.waitingCount, 2)
        queue.setCapacity(2)
        XCTAssertEqual(
            queue.visible.map(\.event.title), ["one", "two"],
            "what was on screen comes back before what never was"
        )
    }
}
