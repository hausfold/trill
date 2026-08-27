import XCTest
@testable import Trill

/// `trill ask` — the one verb that answers back. A notification is normally a
/// one-way street: the daemon takes the event, the caller exits, and whatever
/// the user does about it happens somewhere else entirely. An ask keeps the
/// socket open and turns a banner into a return value, which means three
/// things have to hold, and all three are testable headless:
///
/// 1. the index a caller is told is the index of the label it passed;
/// 2. an ask resolves exactly once, whichever of the several things that can
///    end it happens first;
/// 3. silence never reads as consent.
final class AskRPCTests: XCTestCase {
    private func askRequest(
        title: String = "Push to origin?",
        pills: [String]?,
        timeout: Double? = nil
    ) -> Data {
        var request = SocketProvider.Request(v: 1, verb: "ask", event: nil)
        request.event = NotificationEvent(source: "cli", title: title, kind: .ask)
        request.pills = pills
        request.timeout = timeout
        return try! JSONEncoder.trill.encode(request)
    }

    // MARK: - The wire: pills become indexed replies, minted by the daemon

    func testPillsBecomeRepliesNumberedInTheOrderTheyWerePassed() {
        guard case .ask(let ask) = SocketProvider.handle(
            line: askRequest(pills: ["Allow", "Deny"])
        ) else { return XCTFail("expected an ask") }

        XCTAssertEqual(ask.labels, ["Allow", "Deny"])
        XCTAssertEqual(ask.event.actions.map(\.kind), [.reply, .reply])
        XCTAssertEqual(ask.event.actions.map(\.label), ["Allow", "Deny"])
        // The whole contract in one line: pill N answers with N.
        XCTAssertEqual(ask.event.actions.map(\.target), ["0", "1"])
        XCTAssertEqual(
            ask.event.actions.compactMap { NotificationEvent.Action.replyChoice($0.target) },
            [0, 1]
        )
        XCTAssertTrue(ask.event.actions.allSatisfy(\.isPerformable))
    }

    func testAnAskIsAlwaysAnAskAndNeverCoalesces() {
        var request = SocketProvider.Request(v: 1, verb: "ask", event: nil)
        // A sender trying to make its question a quiet `note` on a thread —
        // both would cost it the answer it is blocked on.
        request.event = NotificationEvent(
            source: "cli", title: "Deploy?", thread: "deploys", kind: .note
        )
        request.pills = ["Ship"]
        guard case .ask(let ask) = SocketProvider.handle(
            line: try! JSONEncoder.trill.encode(request)
        ) else { return XCTFail("expected an ask") }

        XCTAssertEqual(ask.event.kind, .ask, "an ask has to be able to park on the ledge")
        XCTAssertNil(ask.event.thread, "two questions folding into one card hides one of them")
    }

    func testAWordlessOrOverstuffedAskIsRefused() {
        for pills in [[], ["", "   "], ["a", "b", "c", "d"]] {
            guard case .failure = SocketProvider.handle(line: askRequest(pills: pills)) else {
                return XCTFail("expected a refusal for \(pills)")
            }
        }
        guard case .failure = SocketProvider.handle(line: askRequest(title: "   ", pills: ["Ok"]))
        else { return XCTFail("expected a refusal for a blank question") }
    }

    func testPillLabelsAreTrimmedAndCappedOnce() {
        let long = String(repeating: "y", count: 90)
        guard case .ask(let ask) = SocketProvider.handle(
            line: askRequest(pills: ["  Allow  ", long])
        ) else { return XCTFail("expected an ask") }

        XCTAssertEqual(ask.labels.first, "Allow")
        XCTAssertEqual(ask.labels.last?.count, NotificationEvent.Limits.pillLabel)
    }

    func testANonPositiveTimeoutIsNoTimeout() {
        guard case .ask(let ask) = SocketProvider.handle(
            line: askRequest(pills: ["Ok"], timeout: 0)
        ) else { return XCTFail("expected an ask") }
        XCTAssertNil(ask.timeout)
    }

    // MARK: - The face of a question is not a hidden yes

    func testAMultiPillAskHasNoDefaultAction() {
        guard case .ask(let ask) = SocketProvider.handle(
            line: askRequest(pills: ["Allow", "Deny"])
        ) else { return XCTFail("expected an ask") }
        // A stray click on the title of "Push to origin?" must not press Allow.
        XCTAssertFalse(ask.event.hasDefaultAction)
        XCTAssertEqual(ask.event.pillActions.count, 2)
    }

    func testASinglePillAskIsClickableBecauseThereIsNothingElseToPress() {
        guard case .ask(let ask) = SocketProvider.handle(line: askRequest(pills: ["Got it"]))
        else { return XCTFail("expected an ask") }
        XCTAssertTrue(ask.event.hasDefaultAction)
        XCTAssertTrue(ask.event.pillActions.isEmpty, "one action rides the meta row")
    }

    func testAnOutOfRangeReplyTargetNamesNoButton() {
        XCTAssertNil(NotificationEvent.Action.replyChoice("3"))
        XCTAssertNil(NotificationEvent.Action.replyChoice("-1"))
        XCTAssertNil(NotificationEvent.Action.replyChoice("one"))
        XCTAssertNil(NotificationEvent.Action.replyChoice(nil))
        XCTAssertEqual(NotificationEvent.Action.replyChoice("2"), 2)
    }

    // MARK: - The broker: exactly one resolution

    /// The broker answers from whichever thread ended the ask — a pill click
    /// on the main actor, its own timer queue, the socket queue on a hangup —
    /// so a test that just appends to a local `var` is a data race, not a
    /// test. This collects across all three.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedAnswers: [AskBroker.Answer] = []
        private var storedRetractions: [String] = []

        func record(_ answer: AskBroker.Answer) {
            lock.lock(); storedAnswers.append(answer); lock.unlock()
        }

        func retract(_ id: String) {
            lock.lock(); storedRetractions.append(id); lock.unlock()
        }

        var answers: [AskBroker.Answer] { lock.lock(); defer { lock.unlock() }; return storedAnswers }
        var outcomes: [AskBroker.Outcome] { answers.map(\.outcome) }
        var retractions: [String] { lock.lock(); defer { lock.unlock() }; return storedRetractions }
    }

    private func broker(
        claimGrace: TimeInterval = 60,
        recorder: Recorder? = nil,
        onRetract: (@Sendable (String) -> Void)? = nil
    ) -> AskBroker {
        AskBroker(claimGrace: claimGrace) { id in
            recorder?.retract(id)
            onRetract?(id)
        }
    }

    func testAPressedPillAnswersWithItsIndexAndItsLabel() {
        let recorder = Recorder()
        let broker = broker()
        broker.register(id: "q", peer: 1, labels: ["Allow", "Deny"], timeout: nil, resolve: recorder.record)
        broker.claim(id: "q")

        XCTAssertTrue(broker.answer(id: "q", choice: 1))
        XCTAssertEqual(recorder.answers.count, 1)
        XCTAssertEqual(recorder.answers.first?.outcome, .answered)
        XCTAssertEqual(recorder.answers.first?.choice, 1)
        XCTAssertEqual(recorder.answers.first?.label, "Deny")
    }

    func testTheTakedownThatFollowsAnAnswerIsNotASecondReply() {
        let recorder = Recorder()
        let broker = broker()
        broker.register(id: "q", peer: 1, labels: ["Allow", "Deny"], timeout: nil, resolve: recorder.record)

        // Exactly what a pill click does: answer, then take the banner down —
        // and a takedown is itself an abandonment.
        broker.answer(id: "q", choice: 0)
        XCTAssertFalse(broker.abandon(id: "q"))
        XCTAssertEqual(recorder.outcomes, [.answered])
        XCTAssertFalse(broker.isPending("q"))
    }

    func testAnAnswerTheAskNeverOfferedIsRefused() {
        let recorder = Recorder()
        let broker = broker()
        broker.register(id: "q", peer: 1, labels: ["Allow"], timeout: nil, resolve: recorder.record)

        XCTAssertFalse(broker.answer(id: "q", choice: 2), "no such pill — and 2 is an exit code")
        XCTAssertTrue(recorder.answers.isEmpty)
        XCTAssertTrue(broker.isPending("q"))
    }

    func testAWavedAwayQuestionUnblocksItsCallerWithoutAnswering() {
        let recorder = Recorder()
        let broker = broker()
        broker.register(id: "q", peer: 1, labels: ["Allow", "Deny"], timeout: nil, resolve: recorder.record)

        XCTAssertTrue(broker.abandon(id: "q"))
        XCTAssertEqual(recorder.answers.first?.outcome, .dismissed)
        XCTAssertNil(recorder.answers.first?.choice, "silence is not an answer, let alone pill 0")
    }

    func testHangingUpEndsEveryQuestionThatCallerAskedAndTakesThemDown() {
        let recorder = Recorder()
        let broker = broker(recorder: recorder)
        broker.register(id: "mine-1", peer: 7, labels: ["Ok"], timeout: nil, resolve: recorder.record)
        broker.register(id: "mine-2", peer: 7, labels: ["Ok"], timeout: nil, resolve: recorder.record)
        broker.register(id: "theirs", peer: 8, labels: ["Ok"], timeout: nil, resolve: recorder.record)

        broker.cancel(peer: 7)

        XCTAssertEqual(recorder.outcomes, [.canceled, .canceled])
        XCTAssertEqual(Set(recorder.retractions), ["mine-1", "mine-2"])
        XCTAssertTrue(broker.isPending("theirs"), "another caller's question is untouched")
    }

    func testAQuestionNoScreenEverSawIsReportedNotWaitedOut() {
        // A rule dropped it, or the repository deduped it: nothing is coming.
        // Blocking the caller for its full timeout on a banner that will never
        // be drawn is the hang the claim watchdog exists to prevent.
        let recorder = Recorder()
        let broker = broker(claimGrace: 0.05)
        let resolved = expectation(description: "resolved")
        broker.register(id: "q", peer: 1, labels: ["Ok"], timeout: 600) { answer in
            recorder.record(answer)
            resolved.fulfill()
        }
        wait(for: [resolved], timeout: 2)
        XCTAssertEqual(recorder.outcomes, [.dropped])
    }

    func testAClaimedQuestionOutlivesTheWatchdog() {
        let recorder = Recorder()
        let broker = broker(claimGrace: 0.05)
        broker.register(id: "q", peer: 1, labels: ["Ok"], timeout: nil, resolve: recorder.record)
        broker.claim(id: "q")

        let settled = expectation(description: "watchdog ran")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { settled.fulfill() }
        wait(for: [settled], timeout: 2)

        XCTAssertTrue(recorder.answers.isEmpty, "a drawn question waits as long as the user does")
        XCTAssertTrue(broker.isPending("q"))
    }

    func testAClockRunningOutEndsTheQuestionAndTakesTheBannerDown() {
        let recorder = Recorder()
        // Both halves get their own expectation because the broker does them
        // in that order on its timer queue: the caller is unblocked first, the
        // banner comes down after. Waiting only on the answer reads the
        // retraction while it is still in flight.
        let resolved = expectation(description: "resolved")
        let retracted = expectation(description: "retracted")
        let broker = broker(recorder: recorder) { _ in retracted.fulfill() }
        broker.register(id: "q", peer: 1, labels: ["Ok"], timeout: 0.05) { answer in
            recorder.record(answer)
            resolved.fulfill()
        }
        broker.claim(id: "q")
        wait(for: [resolved, retracted], timeout: 2)

        XCTAssertEqual(recorder.outcomes, [.timeout])
        XCTAssertEqual(recorder.retractions, ["q"], "a question with no one behind it can't stay up")
    }

    // MARK: - The queue tells the broker when a banner really ends

    private func ask(_ id: String) -> NotificationEvent {
        NotificationEvent(id: id, source: "lane", title: "needs you \(id)", kind: .ask)
    }

    @MainActor
    func testDismissingABannerReportsItAsDropped() {
        let queue = BannerQueue(capacity: 2, displayDuration: .seconds(3600))
        var dropped: [String] = []
        queue.onDropped = { dropped += $0.map(\.id) }

        queue.enqueue(ask("1"))
        queue.dismiss(id: "1")

        XCTAssertEqual(dropped, ["1"])
    }

    @MainActor
    func testParkingAnAskIsNotDroppingIt() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        var dropped: [String] = []
        queue.onDropped = { dropped += $0.map(\.id) }

        queue.enqueue(ask("1"))
        queue.expire(id: "1")

        XCTAssertEqual(queue.parked.map(\.id), ["1"])
        XCTAssertTrue(dropped.isEmpty, "a parked question is still being asked")

        // …and answering it from the ledge does end it.
        queue.dismiss(id: "1")
        XCTAssertEqual(dropped, ["1"])
    }

    @MainActor
    func testAnAskEvictedOffTheLedgeUnblocksItsCaller() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        var dropped: [String] = []
        queue.onDropped = { dropped += $0.map(\.id) }

        for index in 1...(BannerQueue.parkedCapacity + 1) {
            queue.enqueue(ask("\(index)"))
            queue.expire(id: "\(index)")
        }

        XCTAssertEqual(queue.parked.count, BannerQueue.parkedCapacity)
        XCTAssertEqual(dropped, ["1"], "the oldest yielded — its caller has to hear about it")
    }

    @MainActor
    func testClearingEverythingUnblocksEveryCaller() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        var dropped: Set<String> = []
        queue.onDropped = { dropped.formUnion($0.map(\.id)) }

        queue.enqueue(ask("visible"))
        queue.enqueue(ask("waiting"))
        queue.enqueue(ask("parked"))
        queue.expire(id: "visible")
        queue.dismissAll()

        XCTAssertEqual(dropped, ["visible", "waiting", "parked"])
    }

    // MARK: - Where the two ask features meet

    /// A question can also be answered by *something else* — `trill resolve`,
    /// an event carrying `resolves`, a `--until` poller that came good. The
    /// fin goes; the caller blocked on it has to go with it. Anything else is
    /// a shell that never returns.
    @MainActor
    func testAQuestionResolvedElsewhereUnblocksItsCaller() {
        let queue = BannerQueue(capacity: 2, displayDuration: .seconds(3600))
        var dropped: [String] = []
        queue.onDropped = { dropped += $0.map(\.id) }

        var event = ask("gate")
        event.key = "deploy-gate"
        queue.enqueue(event)
        XCTAssertEqual(queue.resolve(keys: ["deploy-gate"]), 1)

        XCTAssertEqual(dropped, ["gate"], "resolution unblocks; it never answers")
    }

    /// Same, for a question resolved while it was still queued behind a full
    /// screen — that path leaves through `waiting`, not through `dismiss`.
    @MainActor
    func testAQuestionResolvedBeforeItIsEverDrawnUnblocksToo() {
        let queue = BannerQueue(capacity: 0, displayDuration: .seconds(3600))
        var dropped: [String] = []
        queue.onDropped = { dropped += $0.map(\.id) }

        var event = ask("queued")
        event.key = "deploy-gate"
        queue.enqueue(event)
        XCTAssertEqual(queue.resolve(keys: ["deploy-gate"]), 1)

        XCTAssertEqual(dropped, ["queued"])
    }

    /// The ledge outlives the daemon; a `trill ask` caller does not. Its
    /// socket died with the last process, so the pills on a restored fin
    /// could never be honored — and trill draws no dead buttons.
    @MainActor
    func testAFinRestoredFromAPreviousDaemonHasNoPillsLeft() {
        guard case .ask(let request) = SocketProvider.handle(
            line: askRequest(pills: ["Allow", "Deny"])
        ) else { return XCTFail("expected an ask") }

        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        queue.restoreParked([(event: request.event, coalescedCount: 0)])

        let restored = try? XCTUnwrap(queue.parked.first?.event)
        XCTAssertEqual(queue.parked.count, 1, "the question was real — the fin comes back")
        XCTAssertTrue(restored?.actions.isEmpty ?? false)
        XCTAssertFalse(restored?.hasDefaultAction ?? true)
    }

    // MARK: - End to end over a real socket

    /// A caller connects, asks, and *stays connected* — the reply is written
    /// down the same socket much later, by whoever ended the question. This is
    /// the whole claim of the feature ("no other notifier is a two-way
    /// street"), so it is worth proving over an actual unix socket rather than
    /// only in the pieces.
    func testTheAnswerComesBackDownTheSocketTheQuestionArrivedOn() async throws {
        let path = Self.temporarySocketPath()
        defer { unlink(path) }
        let broker = broker()
        let provider = SocketProvider(path: path, askBroker: broker)
        let stream = await provider.events()
        var events = stream.makeAsyncIterator()

        let fd = try Self.connect(to: path)
        defer { close(fd) }
        try Self.write(askLine(pills: ["Allow", "Deny"]), to: fd)

        let event = await events.next()
        let id = try XCTUnwrap(event?.id)
        XCTAssertEqual(event?.kind, .ask)
        XCTAssertEqual(event?.actions.map(\.label), ["Allow", "Deny"])
        XCTAssertTrue(broker.isPending(id), "the caller is still on the wire")

        // …and now, arbitrarily later, the user presses the second pill.
        broker.claim(id: id)
        XCTAssertTrue(broker.answer(id: id, choice: 1))

        let reply = try XCTUnwrap(Self.readLine(from: fd))
        let response = try JSONDecoder.trill.decode(SocketProvider.Response.self, from: reply)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, id)
        XCTAssertEqual(response.choice, 1)
        XCTAssertEqual(response.label, "Deny")
        XCTAssertEqual(response.outcome, AskBroker.Outcome.answered.rawValue)
    }

    /// Ctrl-C at the terminal. The question loses its point the moment the
    /// caller goes away — pressing Allow on it would answer nothing — so the
    /// hangup has to end it and take the banner down.
    func testHangingUpTheSocketRetractsTheQuestion() async throws {
        let path = Self.temporarySocketPath()
        defer { unlink(path) }
        let recorder = Recorder()
        let broker = broker(recorder: recorder)
        let provider = SocketProvider(path: path, askBroker: broker)
        let stream = await provider.events()
        var events = stream.makeAsyncIterator()

        let fd = try Self.connect(to: path)
        try Self.write(askLine(pills: ["Allow", "Deny"]), to: fd)
        let arrived = await events.next()
        let id = try XCTUnwrap(arrived?.id)
        broker.claim(id: id)

        close(fd)

        let gone = expectation(description: "the question ended with its asker")
        // Poll for the retraction itself, not for the entry leaving `pending`:
        // the broker drops the entry first and retracts after, so the latter
        // is a green light one step early.
        Self.poll(until: { !recorder.retractions.isEmpty }, fulfilling: gone)
        await fulfillment(of: [gone], timeout: 3)
        // The outcome itself has nowhere to go — the socket it would have been
        // written to is the one that just closed — so what is observable here
        // is the retraction: the banner comes down. (`.canceled` reaching a
        // resolve handler is covered above, without a socket in the way.)
        XCTAssertEqual(recorder.retractions, [id])
    }

    private func askLine(pills: [String]) -> Data {
        askRequest(pills: pills) + Data([0x0A])
    }

    private static func temporarySocketPath() -> String {
        // Short, because sun_path is 104 bytes and the default temp directory
        // on macOS is most of that already.
        "/tmp/trill-ask-\(UUID().uuidString.prefix(8)).sock"
    }

    private static func connect(to path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, size) }
        }
        guard connected == 0 else {
            close(fd)
            throw XCTSkip("could not connect to the test socket at \(path)")
        }
        // No test hangs the suite waiting for a reply that isn't coming.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private static func write(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard n > 0 else { throw XCTSkip("short write to the test socket") }
                offset += n
            }
        }
    }

    private static func readLine(from fd: Int32) -> Data? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while !buffer.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
        return buffer.firstIndex(of: 0x0A).map { buffer.prefix(upTo: $0) }
    }

    private static func poll(
        until condition: @escaping @Sendable () -> Bool,
        fulfilling expectation: XCTestExpectation,
        deadline: Int = 60
    ) {
        guard deadline > 0 else { return }
        if condition() { return expectation.fulfill() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
            poll(until: condition, fulfilling: expectation, deadline: deadline - 1)
        }
    }

    // MARK: - The CLI: the exit code *is* the answer

    private func response(choice: Int?, label: String?, outcome: String?) -> SocketProvider.Response {
        SocketProvider.Response(
            ok: true, id: "q", error: nil, findings: nil, auditUnavailable: nil,
            choice: choice, label: label, outcome: outcome
        )
    }

    func testTheExitCodeIsTheIndexOfThePillPressed() {
        XCTAssertEqual(
            TrillCLI.renderAsk(response(choice: 0, label: "Allow", outcome: "answered"), json: true),
            0, "the first pill is exit 0, so `trill ask … && git push` reads right"
        )
        XCTAssertEqual(
            TrillCLI.renderAsk(response(choice: 2, label: "Later", outcome: "answered"), json: true),
            2
        )
    }

    func testEverySilenceExitsUnansweredAndNeverZero() {
        for outcome in ["timeout", "dismissed", "dropped", "canceled", nil] {
            XCTAssertEqual(
                TrillCLI.renderAsk(response(choice: nil, label: nil, outcome: outcome), json: true),
                TrillCLI.AskExit.unanswered,
                "nobody answered (\(outcome ?? "no outcome")) — that can never be exit 0"
            )
        }
        // A reply claiming an answer without saying which pill is not an
        // answer either: 0 would mean the first one.
        XCTAssertEqual(
            TrillCLI.renderAsk(response(choice: nil, label: nil, outcome: "answered"), json: true),
            TrillCLI.AskExit.unanswered
        )
    }

    // MARK: - The CLI: parsing

    func testTheQuestionIsPositionalAndTheDefaultPillsAreYesNo() {
        guard case .success(let invocation) = TrillCLI.parseAsk(["Push to origin?"]) else {
            return XCTFail("expected a parse")
        }
        XCTAssertEqual(invocation.request.verb, "ask")
        XCTAssertEqual(invocation.request.event?.title, "Push to origin?")
        XCTAssertEqual(invocation.request.event?.kind, .ask)
        XCTAssertEqual(invocation.request.pills, ["Yes", "No"])
        XCTAssertNil(invocation.request.timeout)
        XCTAssertFalse(invocation.json)
    }

    func testPillsKeepTheirOrderAndTheFlagsThatMatterParse() {
        guard case .success(let invocation) = TrillCLI.parseAsk([
            "Push?", "--pill", "Allow", "--pill", "Deny",
            "--body", "3 commits ahead", "--source", "lane", "--timeout", "90",
            "--key", "deploy-gate", "--until", "pr-merged:142,org/repo",
            "--urgency", "critical", "--redact", "--json",
        ]) else { return XCTFail("expected a parse") }

        XCTAssertEqual(invocation.request.pills, ["Allow", "Deny"])
        XCTAssertEqual(invocation.request.timeout, 90)
        XCTAssertEqual(invocation.request.event?.key, "deploy-gate")
        XCTAssertEqual(invocation.request.event?.until, "pr-merged:142,org/repo")
        XCTAssertEqual(invocation.request.event?.body, "3 commits ahead")
        XCTAssertEqual(invocation.request.event?.source, "lane")
        XCTAssertEqual(invocation.request.event?.urgency, .critical)
        XCTAssertEqual(invocation.request.event?.privacy, .redacted)
        XCTAssertTrue(invocation.json)
    }

    func testAskRefusesWhatItCannotAnswerFor() {
        let refusals: [[String]] = [
            [],                                              // no question
            ["Push?", "--kind", "note"],                     // an ask is an ask
            ["Push?", "--thread", "deploys"],                // questions don't fold
            ["Push?", "and also?"],                          // two questions
            ["Push?", "--pill"],                             // a pill with no label
            ["Push?", "--timeout", "soon"],                  // a clock that isn't one
            ["Push?", "--pill", "a", "--pill", "b", "--pill", "c", "--pill", "d"],
        ]
        for args in refusals {
            guard case .failure = TrillCLI.parseAsk(args) else {
                return XCTFail("expected a refusal for \(args)")
            }
        }
    }
}
