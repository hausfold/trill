import XCTest
@testable import Trill

/// The progress card: one bar, one key, one card for a whole build. Wire
/// format, the CLI's refusal to guess at units, the queue rule that makes a
/// tick an *update* rather than an arrival, and the geometry the bar costs —
/// all headless, like every test here.
final class ProgressCardTests: XCTestCase {
    private func tick(key: String, _ fraction: Double?, id: String = UUID().uuidString) -> NotificationEvent {
        NotificationEvent(
            id: id, source: "haus", key: key, title: "haus rebuild",
            progress: fraction, kind: .pulse
        ).normalized()
    }

    // MARK: - The wire

    func testProgressRoundTripsAndStaysAbsentWhenUnsent() throws {
        let event = NotificationEvent(source: "haus", title: "rebuild", progress: 0.42)
        let decoded = try JSONDecoder.trill.decode(
            NotificationEvent.self, from: JSONEncoder.trill.encode(event)
        )
        XCTAssertEqual(decoded.progress, 0.42)

        let bare = try JSONDecoder.trill.decode(
            NotificationEvent.self, from: Data(#"{"title":"hello"}"#.utf8)
        )
        XCTAssertNil(bare.progress, "most events aren't going anywhere — no bar, not a zero-length one")
    }

    func testNormalizationClampsWhatASenderGotWrong() {
        XCTAssertEqual(NotificationEvent(source: "s", title: "t", progress: 1.4).normalized().progress, 1)
        XCTAssertEqual(NotificationEvent(source: "s", title: "t", progress: -3).normalized().progress, 0)
        XCTAssertNil(
            NotificationEvent(source: "s", title: "t", progress: .nan).normalized().progress,
            "a divide-by-zero NaN is no bar at all, not a bar of unknown length"
        )
    }

    func testOnlyAnUnfinishedBarIsATick() {
        XCTAssertTrue(NotificationEvent(source: "s", title: "t", progress: 0.5).isProgressTick)
        XCTAssertFalse(NotificationEvent(source: "s", title: "t", progress: 1).isProgressTick, "the ending is history")
        XCTAssertFalse(NotificationEvent(source: "s", title: "t").isProgressTick)
    }

    // MARK: - The CLI

    func testProgressTakesAFractionOrAPercentAndNothingElse() {
        XCTAssertEqual(TrillCLI.parseProgress("0.42"), 0.42)
        XCTAssertEqual(TrillCLI.parseProgress("42%"), 0.42)
        XCTAssertEqual(TrillCLI.parseProgress("1"), 1)
        XCTAssertEqual(TrillCLI.parseProgress("100%"), 1)
        // The whole reason for the `%`: read as a fraction this is 4200%,
        // read as a percentage it makes `--progress 1` ambiguous.
        XCTAssertNil(TrillCLI.parseProgress("42"))
        XCTAssertNil(TrillCLI.parseProgress("101%"))
        XCTAssertNil(TrillCLI.parseProgress("-1"))
        XCTAssertNil(TrillCLI.parseProgress("soon"))
    }

    func testABarWithNoKindIsARunningJob() throws {
        guard case .success(let event) = TrillCLI.parseSend(
            ["--title", "build", "--progress", "30%", "--key", "haus"]
        ) else { return XCTFail("--progress should parse") }
        XCTAssertEqual(event.kind, .pulse)
        XCTAssertEqual(event.progress, 0.3)

        guard case .success(let done) = TrillCLI.parseSend(
            ["--title", "built", "--progress", "1", "--key", "haus", "--kind", "done"]
        ) else { return XCTFail("--kind should still win") }
        XCTAssertEqual(done.kind, .done)

        guard case .failure = TrillCLI.parseSend(
            ["--title", "build", "--progress", "42", "--key", "haus"]
        ) else {
            return XCTFail("a bare 42 is refused at the call site, not silently read as 4200%")
        }
    }

    func testABarNeedsAKeyOrItIsFiftyBannersInsteadOfOneCard() {
        guard case .failure(let reason) = TrillCLI.parseSend(["--title", "build", "--progress", "30%"]) else {
            return XCTFail("a keyless --progress leaves no trace anywhere: not one card, not the inbox")
        }
        XCTAssertTrue(reason.contains("--key"), "the refusal has to say what is missing")

        guard case .success = TrillCLI.parseSend(
            ["--title", "build", "--progress", "30%", "--key", "haus"]
        ) else { return XCTFail("--progress with a key is the whole point") }
    }

    // MARK: - The queue rule

    @MainActor
    func testATickReplacesItsOwnCardInsteadOfStackingOrFolding() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue.enqueue(tick(key: "haus", 0.1, id: "first"))
        queue.enqueue(tick(key: "haus", 0.4))
        queue.enqueue(tick(key: "haus", 0.9))

        XCTAssertEqual(queue.visible.count, 1, "one build, one card")
        XCTAssertEqual(queue.visible.first?.event.progress, 0.9, "the newest reading is the card")
        XCTAssertEqual(
            queue.visible.first?.id, "first",
            "the entry keeps its id — the panel is updated, never torn down and rebuilt"
        )
        XCTAssertEqual(
            queue.visible.first?.coalescedCount, 0,
            "a tick is not a thread-mate: nothing folds in behind the face"
        )
    }

    @MainActor
    func testTheEndingLandsOnTheCardTheBuildWasAlreadyUsing() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue.enqueue(tick(key: "haus", 0.6, id: "first"))
        queue.enqueue(NotificationEvent(
            id: "last", source: "haus", key: "haus", title: "haus rebuilt", kind: .done
        ).normalized())

        XCTAssertEqual(queue.visible.count, 1, "the done replaces the bar rather than landing beside it")
        XCTAssertEqual(queue.visible.first?.event.kind, .done)
        XCTAssertNil(queue.visible.first?.event.progress)
    }

    @MainActor
    func testTwoBuildsAreTwoCardsAndAKeyAloneIsStillTwoArrivals() {
        let queue = BannerQueue(capacity: 4, displayDuration: .seconds(3600))
        queue.enqueue(tick(key: "haus", 0.2))
        queue.enqueue(tick(key: "trill", 0.2))
        XCTAssertEqual(queue.visible.count, 2, "one card per key")

        // Nothing here carries progress, so the old rule stands: a re-send is
        // a second arrival (the ledge's supersede is the only other exception).
        let plain = NotificationEvent(source: "cli", key: "note", title: "hello")
        queue.enqueue(plain.normalized())
        queue.enqueue(NotificationEvent(source: "cli", key: "note", title: "hello again").normalized())
        XCTAssertEqual(queue.visible.count, 4)
    }

    @MainActor
    func testABarNeverTakesAQuestionOffTheLedgeOrOffTheScreen() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        var dropped: [NotificationEvent] = []
        queue.onDropped = { dropped.append(contentsOf: $0) }

        // A build and an unanswered question that happen to share a key.
        queue.enqueue(NotificationEvent(
            id: "ask", source: "lane", key: "haus", title: "rebuild this?", kind: .ask
        ).normalized())
        queue.expire(id: "ask")
        XCTAssertEqual(queue.parked.map(\.id), ["ask"])

        queue.enqueue(tick(key: "haus", 0.3))
        XCTAssertEqual(
            queue.parked.map(\.id), ["ask"],
            "a bar may replace a bar; only an arrival may replace a question"
        )
        XCTAssertEqual(queue.visible.count, 1, "the bar still gets its own card")
        XCTAssertTrue(dropped.isEmpty, "nothing left the compositor, so nobody's asker was unblocked")

        // The same rule on screen: a visible ask is never overwritten in place.
        let queue2 = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue2.enqueue(NotificationEvent(
            id: "ask2", source: "lane", key: "haus", title: "rebuild this?", kind: .ask
        ).normalized())
        queue2.enqueue(tick(key: "haus", 0.3))
        XCTAssertEqual(queue2.visible.count, 2, "the question keeps its card, the bar lands beside it")
        XCTAssertEqual(queue2.visible.first?.event.kind, .ask)
    }

    @MainActor
    func testASwattedBarStaysGoneUntilItFinishes() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue.enqueue(tick(key: "haus", 0.2, id: "first"))
        queue.dismiss(id: "first")
        XCTAssertEqual(queue.visible.count, 0)

        queue.enqueue(tick(key: "haus", 0.5))
        queue.enqueue(tick(key: "haus", 0.8))
        XCTAssertEqual(
            queue.visible.count, 0,
            "a driver ticks every couple of seconds — the card you swatted must not come straight back"
        )

        queue.enqueue(NotificationEvent(
            id: "done", source: "haus", key: "haus", title: "haus rebuilt", kind: .done
        ).normalized())
        XCTAssertEqual(
            queue.visible.map(\.id), ["done"],
            "you asked for the bar to go away, not to stop being told it finished"
        )

        // The hush is spent: the next build under that key draws again.
        queue.dismiss(id: "done")
        queue.enqueue(tick(key: "haus", 0.1, id: "second"))
        XCTAssertEqual(queue.visible.map(\.id), ["second"], "dismissing the ending hushes nothing")
    }

    @MainActor
    func testATickTakingOverACardDropsTheFoldThatCardWasWearing() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue.enqueue(NotificationEvent(
            id: "a", source: "haus", key: "haus", title: "step one", thread: "build"
        ).normalized())
        queue.enqueue(NotificationEvent(
            id: "b", source: "haus", key: "haus", title: "step two", thread: "build"
        ).normalized())
        XCTAssertEqual(queue.visible.first?.coalescedCount, 1, "same thread, inside the window: folded")

        queue.enqueue(tick(key: "haus", 0.6))
        XCTAssertEqual(
            queue.visible.first?.coalescedCount, 0,
            "the fold belonged to the events that folded in, not to the job"
        )
        XCTAssertEqual(queue.visible.first?.folded, [], "a bar over \"+1 more in this thread\" lists a stranger")
    }

    @MainActor
    func testAnEndingSentAsAFaultIsReRankedAndNotJustRewritten() {
        // One slot, so everything after the first card waits.
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        queue.enqueue(NotificationEvent(id: "held", source: "s", title: "occupies the slot").normalized())
        queue.enqueue(tick(key: "haus", 0.4, id: "bar"))
        queue.enqueue(NotificationEvent(id: "note1", source: "s", title: "chatter").normalized())
        queue.enqueue(NotificationEvent(id: "note2", source: "s", title: "chatter").normalized())
        XCTAssertEqual(queue.waitingCount, 3)

        queue.enqueue(NotificationEvent(
            id: "failed", source: "haus", key: "haus", title: "rebuild failed",
            kind: .fault, urgency: .critical
        ).normalized())
        XCTAssertEqual(queue.waitingCount, 3, "the fault took over the bar's entry rather than landing beside it")

        queue.dismiss(id: "held")
        XCTAssertEqual(
            queue.visible.first?.event.id, "failed",
            "an ending that arrives critical takes a critical's place in line, not the pulse's"
        )
    }

    // MARK: - The ledge (a build outlives one card's worth of screen)

    /// A job's card gets what any card gets — once — and then keeps
    /// reporting from the edge.
    @MainActor
    func testAJobParksAsAFinInsteadOfTakingTheRestOfTheBuildWithIt() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue.enqueue(tick(key: "haus", 0.2, id: "bar"))
        queue.expire(id: "bar")

        XCTAssertEqual(queue.visible.count, 0)
        XCTAssertEqual(queue.parked.map(\.id), ["bar"], "the bar went to the ledge, not away")

        // The ending is not a tick: told once, it is simply gone.
        let queue2 = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue2.enqueue(NotificationEvent(
            id: "done", source: "haus", key: "haus", title: "haus rebuilt", kind: .done
        ).normalized())
        queue2.expire(id: "done")
        XCTAssertTrue(queue2.parked.isEmpty, "an ending that timed out was seen — it doesn't park")
    }

    @MainActor
    func testTicksKeepFillingTheFinAndNeverBannerAgainMidBuild() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue.enqueue(tick(key: "haus", 0.2, id: "bar"))
        queue.expire(id: "bar")

        queue.enqueue(tick(key: "haus", 0.5))
        queue.enqueue(tick(key: "haus", 0.8))

        XCTAssertEqual(queue.visible.count, 0, "a build must not shove itself back in front of you every tick")
        XCTAssertEqual(queue.parked.map(\.id), ["bar"], "same fin, same slot on the edge")
        XCTAssertEqual(queue.parked.first?.event.progress, 0.8, "and it fills")
    }

    @MainActor
    func testTheEndingTakesTheFinDownAndDrawsTheOneCardWorthDrawing() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        var dropped: [NotificationEvent] = []
        queue.onDropped = { dropped.append(contentsOf: $0) }
        queue.enqueue(tick(key: "haus", 0.4, id: "bar"))
        queue.expire(id: "bar")

        queue.enqueue(NotificationEvent(
            id: "done", source: "haus", key: "haus", title: "haus rebuilt",
            progress: 1, kind: .done
        ).normalized())

        XCTAssertTrue(queue.parked.isEmpty, "the fin comes down on its own — that is what you were waiting for")
        XCTAssertEqual(queue.visible.map(\.id), ["done"], "the ending is an arrival and gets a card")
        XCTAssertTrue(dropped.isEmpty, "nothing was lost or abandoned — the job finished")

        // The same ending sent without a bar (the driver's failure path) takes
        // the fin down too, through `supersedeParked`.
        let queue2 = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue2.enqueue(tick(key: "haus", 0.4, id: "bar"))
        queue2.expire(id: "bar")
        queue2.enqueue(NotificationEvent(
            id: "failed", source: "haus", key: "haus", title: "rebuild failed",
            kind: .fault, urgency: .critical
        ).normalized())
        XCTAssertTrue(queue2.parked.isEmpty)
        XCTAssertEqual(queue2.visible.map(\.id), ["failed"])
    }

    @MainActor
    func testABarsFinYieldsBeforeAQuestionDoes() {
        let queue = BannerQueue(capacity: 10, displayDuration: .seconds(3600))
        var dropped: [NotificationEvent] = []
        queue.onDropped = { dropped.append(contentsOf: $0) }

        queue.enqueue(tick(key: "haus", 0.3, id: "bar"))
        queue.expire(id: "bar")
        for i in 1...BannerQueue.parkedCapacity {
            let id = "ask\(i)"
            queue.enqueue(NotificationEvent(id: id, source: "lane", title: "needs you", kind: .ask))
            queue.expire(id: id)
        }

        XCTAssertEqual(
            queue.parked.map(\.id), ["ask1", "ask2", "ask3", "ask4", "ask5"],
            "the sixth fin evicts the running job, never the oldest question"
        )
        XCTAssertEqual(dropped.map(\.id), ["bar"], "and only the bar's caller — which nobody was blocked on")
    }

    @MainActor
    func testSwattingTheFinHushesTheRestOfTheBuildJustLikeSwattingTheCard() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue.enqueue(tick(key: "haus", 0.2, id: "bar"))
        queue.expire(id: "bar")
        queue.dismiss(id: "bar")

        queue.enqueue(tick(key: "haus", 0.6))
        XCTAssertTrue(queue.parked.isEmpty, "you took the fin off the edge; it must not put itself back")
        XCTAssertTrue(queue.visible.isEmpty, "and it must not come back as a banner either")

        queue.enqueue(NotificationEvent(
            id: "done", source: "haus", key: "haus", title: "haus rebuilt", kind: .done
        ).normalized())
        XCTAssertEqual(queue.visible.map(\.id), ["done"], "the ending still lands")
    }

    @MainActor
    func testAFinIsNeverRestoredForABuildThatDiedWithTheDaemon() {
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(3600))
        queue.restoreParked([
            (event: tick(key: "haus", 0.4, id: "bar"), coalescedCount: 0),
            (
                event: NotificationEvent(id: "ask", source: "lane", title: "needs you", kind: .ask),
                coalescedCount: 0
            )
        ])
        XCTAssertEqual(
            queue.parked.map(\.id), ["ask"],
            "a bar frozen at 40% that nothing will ever finish is not worth a fin"
        )
    }

    @MainActor
    func testAJobThatStopsReportingLosesItsFinAndAQuestionDoesNot() async throws {
        let queue = BannerQueue(
            capacity: 3, displayDuration: .seconds(3600), stallTimeout: 0.15
        )
        queue.enqueue(tick(key: "haus", 0.3, id: "bar"))
        queue.expire(id: "bar")
        queue.enqueue(NotificationEvent(id: "ask", source: "lane", title: "needs you", kind: .ask))
        queue.expire(id: "ask")

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(
            queue.parked.map(\.id), ["ask"],
            "liveness is the sender's job: a driver that died loses its fin, a question waits"
        )
    }

    @MainActor
    func testATickDoesNotRestartTheCardsClock() async throws {
        // A driver ticks faster than the clock runs (three seconds against
        // six), so a card that re-armed on every reading would sit on screen
        // for the whole rebuild. Scaled down: the card's second is up at
        // 1.0 s, a re-armed one wouldn't be until 1.6 s.
        let queue = BannerQueue(capacity: 3, displayDuration: .seconds(1), coalesceWindow: 0)
        queue.enqueue(tick(key: "haus", 0.1, id: "bar"))

        try await Task.sleep(for: .milliseconds(600))
        queue.enqueue(tick(key: "haus", 0.5))
        try await Task.sleep(for: .milliseconds(700))

        XCTAssertTrue(queue.visible.isEmpty, "one card's worth of screen, then the edge")
        XCTAssertEqual(queue.parked.map(\.id), ["bar"])
        XCTAssertEqual(queue.parked.first?.event.progress, 0.5, "carrying the newest reading it had")
    }

    // MARK: - What the bar costs

    func testTheBarGetsItsOwnRowAndPaysForItOnce() {
        let bare = BannerGeometry.cardSize(foldedCount: 0, expanded: false, maxRows: 0)
        let withBar = BannerGeometry.cardSize(
            foldedCount: 0, expanded: false, maxRows: 0, hasProgress: true
        )
        XCTAssertEqual(withBar.height, bare.height + BannerGeometry.progressRowHeight)
        XCTAssertEqual(withBar.width, bare.width, "cards only ever grow downward")

        let withBoth = BannerGeometry.cardSize(
            foldedCount: 0, expanded: false, maxRows: 0, actionCount: 2, hasProgress: true
        )
        XCTAssertEqual(
            withBoth.height,
            bare.height + BannerGeometry.actionRowHeight + BannerGeometry.progressRowHeight,
            "a card can have both a bar and pills"
        )
    }

    func testThePercentageNeverReadsDoneBeforeItIs() {
        XCTAssertEqual(BannerView.percent(0), "0%")
        XCTAssertEqual(BannerView.percent(0.425), "42%")
        XCTAssertEqual(BannerView.percent(0.999), "99%", "rounding to 100 mid-build is the one unforgivable number")
        XCTAssertEqual(BannerView.percent(1), "100%")
    }
}
