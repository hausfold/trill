import XCTest
@testable import Trill

/// The ledge: unattended asks park as fins instead of vanishing. Queue
/// truth first (the third bucket), then the pure fin geometry, then the
/// `trill inbox` wire format — all headless, like every test here.
final class LedgeTests: XCTestCase {
    private func ask(_ id: String) -> NotificationEvent {
        NotificationEvent(id: id, source: "lane", title: "needs you \(id)", kind: .ask)
    }

    // MARK: - Parking (queue truth)

    @MainActor
    func testAnUnattendedAskParksInsteadOfVanishing() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        queue.enqueue(ask("1"))
        queue.enqueue(NotificationEvent(id: "2", source: "s", title: "note"))

        // The dismiss clock running out is `expire`, not `dismiss`.
        queue.expire(id: "1")
        XCTAssertEqual(queue.parked.map(\.id), ["1"], "an ask nobody answered parks")
        XCTAssertEqual(
            queue.visible.map(\.id), ["2"],
            "parking frees the slot like a dismissal would"
        )

        queue.expire(id: "2")
        XCTAssertEqual(queue.visible.count, 0)
        XCTAssertEqual(
            queue.parked.map(\.id), ["1"],
            "only asks park — an expired note is simply gone (it survives in the inbox)"
        )
    }

    @MainActor
    func testAUsersOwnDismissalNeverParks() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        queue.enqueue(ask("1"))

        // The ✕, a pill, the face — all land on `dismiss`: they saw it,
        // and answered questions don't belong on the ledge.
        queue.dismiss(id: "1")
        XCTAssertTrue(queue.parked.isEmpty)
    }

    @MainActor
    func testTheLedgeHoldsFiveAndOlderAsksYield() {
        let queue = BannerQueue(capacity: 10, displayDuration: .seconds(3600))
        for i in 1...(BannerQueue.parkedCapacity + 1) {
            queue.enqueue(ask("\(i)"))
            queue.expire(id: "\(i)")
        }

        XCTAssertEqual(
            queue.parked.map(\.id), ["2", "3", "4", "5", "6"],
            "the sixth ask evicts the oldest — it survives in the inbox, not here"
        )
    }

    @MainActor
    func testAnsweringOrDismissingRemovesAParkedAsk() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        queue.enqueue(ask("1"))
        queue.expire(id: "1")
        queue.setParkedHover(true, id: "1")

        // Both the card's ✕ and its pills route through `dismiss`.
        queue.dismiss(id: "1")
        XCTAssertTrue(queue.parked.isEmpty)

        // The hover died with its entry; the next parked ask must not
        // arrive pre-expanded off a stale id.
        queue.enqueue(ask("1"))
        queue.expire(id: "1")
        XCTAssertFalse(queue.parked[0].expanded)
    }

    @MainActor
    func testHoverSlidesExactlyOneCardOutAndStaleExitsDontCloseIt() {
        let queue = BannerQueue(capacity: 2, displayDuration: .seconds(3600))
        queue.enqueue(ask("1"))
        queue.enqueue(ask("2"))
        queue.expire(id: "1")
        queue.expire(id: "2")

        queue.setParkedHover(true, id: "1")
        XCTAssertEqual(queue.parked.map(\.expanded), [true, false])

        // Entering fin 2 can beat leaving fin 1 — the takeover wins, and
        // fin 1's late exit must not collapse it.
        queue.setParkedHover(true, id: "2")
        queue.setParkedHover(false, id: "1")
        XCTAssertEqual(queue.parked.map(\.expanded), [false, true])

        queue.setParkedHover(false, id: "2")
        XCTAssertEqual(queue.parked.map(\.expanded), [false, false])
    }

    @MainActor
    func testParkedAsksSurviveTopologyChangesAndDieWithDismissAll() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue.enqueue(ask("1"))
        queue.expire(id: "1")

        // Fins are re-rendered from this bucket on every rebuild; the
        // bucket itself must not care what the display is doing.
        queue.setCapacity(0)
        queue.setCapacity(3)
        XCTAssertEqual(queue.parked.map(\.id), ["1"])

        queue.dismissAll()
        XCTAssertTrue(queue.parked.isEmpty, "a deliberate sweep sweeps the ledge too")
    }

    @MainActor
    func testExpiringTheHoveredBannerUnsticksTheQueue() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        queue.enqueue(ask("1"))
        queue.enqueue(NotificationEvent(id: "2", source: "s", title: "waiting"))

        queue.setHover(true, id: "1")
        // Hover normally cancels the clock, but a test (or a race) can
        // expire the hovered card; the stack's hover must not survive a
        // banner that left the stack.
        queue.expire(id: "1")
        XCTAssertEqual(queue.visible.map(\.id), ["2"], "the freed slot refills")
        XCTAssertEqual(queue.parked.map(\.id), ["1"])
    }

    // MARK: - Fin geometry (pure)

    private let laptop = ScreenDescriptor(
        id: "laptop",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944)
    )

    func testFinsHugTheRightEdgeCenteredAsAGroup() {
        let frames = BannerGeometry.Ledge.finFrames(on: laptop, count: 3)

        XCTAssertEqual(frames.count, 3)
        for frame in frames {
            XCTAssertEqual(
                frame.maxX, laptop.visibleFrame.maxX,
                "fins are flush to the screen edge — the edge is the hover target"
            )
            XCTAssertEqual(frame.size, BannerGeometry.Ledge.finSize)
        }
        XCTAssertEqual(
            frames[0].minY - frames[1].maxY, BannerGeometry.Ledge.finGap,
            "a spaced column, top to bottom in parked (oldest-first) order"
        )
        let groupMidY = (frames[0].maxY + frames[2].minY) / 2
        XCTAssertEqual(
            groupMidY, laptop.visibleFrame.midY, accuracy: 0.5,
            "the group centers on the visible frame, away from the banner corner"
        )
    }

    func testNoFinsMeansNoFrames() {
        XCTAssertTrue(BannerGeometry.Ledge.finFrames(on: laptop, count: 0).isEmpty)
    }

    func testTheSlidOutCardStaysFlushToTheEdgeAndOnScreen() {
        let fins = BannerGeometry.Ledge.finFrames(on: laptop, count: 1)
        let card = BannerGeometry.Ledge.cardFrame(
            finFrame: fins[0], cardSize: BannerGeometry.size, on: laptop
        )

        XCTAssertEqual(
            card.maxX, laptop.visibleFrame.maxX,
            "flush, not inset — the pointer that opened it is at the edge, and a gap would collapse it"
        )
        XCTAssertEqual(card.midY, fins[0].midY, accuracy: 0.5, "centered on its fin")
        XCTAssertTrue(laptop.visibleFrame.contains(card))
    }

    func testACardNearTheFrameEdgeClampsInsteadOfEscaping() {
        // A fin pinned to the bottom of a short display: the card centered
        // on it would run off screen, so it slides up instead.
        let short = ScreenDescriptor(
            id: "short",
            frame: CGRect(x: 0, y: 0, width: 800, height: 200),
            visibleFrame: CGRect(x: 0, y: 0, width: 800, height: 200)
        )
        let fin = CGRect(x: 792, y: 0, width: 8, height: 56)
        let card = BannerGeometry.Ledge.cardFrame(
            finFrame: fin, cardSize: BannerGeometry.size, on: short
        )
        XCTAssertGreaterThanOrEqual(card.minY, short.visibleFrame.minY)
        XCTAssertLessThanOrEqual(card.maxY, short.visibleFrame.maxY)
    }

    // MARK: - `trill inbox` wire format (pure, no socket)

    func testSocketHandlerParsesTheInboxVerb() {
        guard case .inbox(let asksOnly) = SocketProvider.handle(
            line: Data(#"{"v":1,"verb":"inbox","asks":true}"#.utf8)
        ) else { return XCTFail("expected inbox") }
        XCTAssertTrue(asksOnly)

        guard case .inbox(let bare) = SocketProvider.handle(
            line: Data(#"{"v":1,"verb":"inbox"}"#.utf8)
        ) else { return XCTFail("expected inbox") }
        XCTAssertFalse(bare, "no filter means the whole inbox")
    }

    func testCLIParsesInboxFlags() {
        XCTAssertEqual(
            TrillCLI.parseInbox([]),
            .success(SocketProvider.Request(v: 1, verb: "inbox", event: nil))
        )
        XCTAssertEqual(
            TrillCLI.parseInbox(["--asks"]),
            .success(SocketProvider.Request(v: 1, verb: "inbox", event: nil, asks: true))
        )
        if case .success = TrillCLI.parseInbox(["--wat"]) {
            XCTFail("unknown flags must fail, not be swallowed")
        }
    }
}
