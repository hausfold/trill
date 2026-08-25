import XCTest
@testable import Trill

/// Resolution: a parked question answering itself. Three roads in — a
/// `trill resolve` from anywhere, an event that carries `resolves`, and a
/// rules-declared poller — one terminal, and nothing on it that can put a
/// question back. Headless — no socket, no display — but the runner tests
/// do start real (tiny) processes, because "there is no shell in this path"
/// is a claim only a real process can back.
final class ResolutionTests: XCTestCase {
    private func ask(_ id: String, key: String? = nil, until: String? = nil) -> NotificationEvent {
        NotificationEvent(id: id, source: "lane", key: key, until: until,
                          title: "needs you \(id)", kind: .ask)
    }

    // MARK: - Names

    func testAnEventIsResolvableByItsIdWithNoKeyAtAll() {
        let event = ask("abc")
        XCTAssertEqual(event.resolutionKey, "abc")
        XCTAssertEqual(event.resolutionNames, ["abc"])
    }

    func testAKeyIsASecondNameNotAReplacement() {
        let event = ask("abc", key: "pr-142")
        XCTAssertEqual(event.resolutionKey, "pr-142")
        XCTAssertEqual(
            event.resolutionNames, ["abc", "pr-142"],
            "the id `trill send` printed keeps working after a --key is added"
        )
    }

    func testResolutionFieldsSurviveTheWire() throws {
        let event = NotificationEvent(
            source: "lane", key: "pr-142", resolves: ["a", "b"], until: "pr-merged:142",
            title: "review me", kind: .ask
        )
        let round = try JSONDecoder.trill.decode(
            NotificationEvent.self, from: JSONEncoder.trill.encode(event)
        )
        XCTAssertEqual(round.key, "pr-142")
        XCTAssertEqual(round.resolves, ["a", "b"])
        XCTAssertEqual(round.until, "pr-merged:142")
    }

    func testNormalizationCapsAndTrimsTheNewFields() {
        let event = NotificationEvent(
            source: "lane", key: "  pr-142  ",
            resolves: ["  a  ", "", "  "] + (1...20).map { "k\($0)" },
            until: "  pr-merged  ", title: "t"
        ).normalized()

        XCTAssertEqual(event.key, "pr-142")
        XCTAssertEqual(event.until, "pr-merged")
        XCTAssertEqual(event.resolves.first, "a")
        XCTAssertFalse(event.resolves.contains(""), "blank keys would match nothing and cost a scan")
        XCTAssertEqual(event.resolves.count, NotificationEvent.Limits.resolvedKeys)
    }

    // MARK: - The queue

    @MainActor
    func testResolvingClearsBannersFinsAndTheWaitingLine() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        queue.enqueue(ask("visible", key: "k1"))
        queue.enqueue(ask("waiting", key: "k2"))
        queue.enqueue(ask("parked", key: "k3"))
        queue.expire(id: "parked")

        XCTAssertEqual(queue.resolve(keys: ["k1"]), 1)
        XCTAssertFalse(queue.visible.contains { $0.id == "visible" })
        XCTAssertEqual(queue.resolve(keys: ["k2"]), 1, "a question waiting for a slot is still a question")
        XCTAssertEqual(queue.resolve(keys: ["k3"]), 1)
        XCTAssertTrue(queue.parked.isEmpty)
    }

    @MainActor
    func testResolvingByIdWorksWithoutAKey() {
        let queue = BannerQueue(capacity: 2, displayDuration: .seconds(3600))
        queue.enqueue(ask("abc"))
        queue.expire(id: "abc")
        XCTAssertEqual(queue.resolve(keys: ["abc"]), 1, "the printed id is a name like any other")
    }

    @MainActor
    func testResolvingIsIdempotentAndNeverReopensAQuestion() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        queue.enqueue(ask("1", key: "k"))
        queue.expire(id: "1")

        XCTAssertEqual(queue.resolve(keys: ["k"]), 1)
        XCTAssertEqual(
            queue.resolve(keys: ["k"]), 0,
            "a hook that fires twice is not an error — and the second call must not conjure a fin"
        )
        XCTAssertTrue(queue.parked.isEmpty)
        XCTAssertEqual(queue.resolve(keys: []), 0, "resolving nothing resolves nothing")
    }

    @MainActor
    func testAReSentAskSupersedesItsOwnFinInsteadOfGrowingASecond() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        queue.enqueue(ask("first", key: "lane-blocked"))
        queue.expire(id: "first")
        XCTAssertEqual(queue.parked.map(\.id), ["first"])

        // The lane says "still blocked" ten minutes later. One question, one fin.
        queue.enqueue(ask("second", key: "lane-blocked"))
        XCTAssertTrue(queue.parked.isEmpty, "the old fin yields to the fresh banner")
        queue.expire(id: "second")
        XCTAssertEqual(queue.parked.map(\.id), ["second"])

        // A different question keeps its own fin.
        queue.enqueue(ask("other", key: "elsewhere"))
        queue.expire(id: "other")
        XCTAssertEqual(queue.parked.map(\.id), ["second", "other"])
    }

    // MARK: - Restore

    @MainActor
    func testRestoredFinsComeBackCollapsedAndWithinCapacity() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        let restored = (1...(BannerQueue.parkedCapacity + 2)).map {
            (event: ask("r\($0)"), coalescedCount: $0)
        }
        queue.restoreParked(restored)

        XCTAssertEqual(queue.parked.count, BannerQueue.parkedCapacity)
        XCTAssertEqual(
            queue.parked.map(\.id), ["r3", "r4", "r5", "r6", "r7"],
            "over capacity, the oldest yields — same rule a live ledge follows"
        )
        XCTAssertEqual(queue.parked.map(\.coalescedCount), [3, 4, 5, 6, 7], "the burst count survives")
        XCTAssertTrue(queue.parked.allSatisfy { !$0.expanded }, "nothing comes back slid out")
    }

    @MainActor
    func testRestoreNeverDuplicatesWhatIsAlreadyParked() {
        let queue = BannerQueue(capacity: 1, displayDuration: .seconds(3600))
        queue.enqueue(ask("live"))
        queue.expire(id: "live")
        queue.restoreParked([(event: ask("live"), coalescedCount: 9)])

        XCTAssertEqual(queue.parked.map(\.id), ["live"])
        XCTAssertEqual(queue.parked[0].coalescedCount, 0, "live beats remembered")
    }

    // MARK: - Wire and CLI

    func testSocketHandlerParsesResolveAndRefusesEmptyKeys() {
        guard case .resolve(let keys) = SocketProvider.handle(
            line: Data(#"{"v":1,"verb":"resolve","keys":["pr-142"," "]}"#.utf8)
        ) else { return XCTFail("expected resolve") }
        XCTAssertEqual(keys, ["pr-142"], "blank keys are dropped, not matched")

        guard case .failure = SocketProvider.handle(
            line: Data(#"{"v":1,"verb":"resolve","keys":[]}"#.utf8)
        ) else { return XCTFail("a resolve naming nothing is a caller bug, not a no-op") }
    }

    func testCLIParsesResolve() {
        XCTAssertEqual(
            TrillCLI.parseResolve(["pr-142", "deploy"]),
            .success(SocketProvider.Request(v: 1, verb: "resolve", event: nil, keys: ["pr-142", "deploy"]))
        )
        if case .success = TrillCLI.parseResolve([]) {
            XCTFail("resolve wants at least one key")
        }
        if case .success = TrillCLI.parseResolve(["--json"]) {
            XCTFail("a flag here is a typo — resolving a fin called '--json' helps nobody")
        }
    }

    func testCLISendCarriesTheResolutionFlags() {
        guard case .success(let event) = TrillCLI.parseSend([
            "--title", "review me", "--kind", "ask",
            "--key", "pr-142", "--resolves", "old-1", "--resolves", "old-2",
            "--until", "pr-merged:142,hausfold/trill",
        ]) else { return XCTFail("expected a parsed event") }

        XCTAssertEqual(event.key, "pr-142")
        XCTAssertEqual(event.resolves, ["old-1", "old-2"])
        XCTAssertEqual(event.until, "pr-merged:142,hausfold/trill")

        if case .success = TrillCLI.parseSend(["--title", "x", "--until"]) {
            XCTFail("--until with no value must fail at the call site")
        }
    }

    // MARK: - Invocations (pure)

    func testInvocationSplitsNameFromArguments() {
        guard case .success(let bare) = ResolverInvocation.parse("pr-merged") else {
            return XCTFail("a bare name is a valid invocation")
        }
        XCTAssertEqual(bare, ResolverInvocation(name: "pr-merged", args: []))

        guard case .success(let withArgs) = ResolverInvocation.parse(" pr-merged:142,hausfold/trill ") else {
            return XCTFail("expected args")
        }
        XCTAssertEqual(withArgs.name, "pr-merged")
        XCTAssertEqual(withArgs.args, ["142", "hausfold/trill"])
    }

    func testInvocationRefusesFlagsBlanksAndFloods() {
        for bad in ["", ":x", "name:-r", "name:", "name:a,,b"] {
            if case .success = ResolverInvocation.parse(bad) {
                XCTFail("'\(bad)' should be refused")
            }
        }
        let flood = "name:" + (1...(ResolverInvocation.maxArgs + 1)).map(String.init).joined(separator: ",")
        if case .success = ResolverInvocation.parse(flood) {
            XCTFail("more arguments than there are placeholders is a sender bug")
        }
        // The whole point of the '-' rule: `gh pr view $1` must not become
        // `gh pr view --repo somewhere-else`.
        if case .success = ResolverInvocation.parse("pr-merged:--repo") {
            XCTFail("arguments are values, never flags")
        }
    }

    // MARK: - Plans (pure)

    private func resolver(
        run: [String]? = nil, get: String? = nil,
        when: RuleSet.Resolver.Predicate? = nil,
        env: [String: String]? = nil
    ) -> RuleSet.Resolver {
        RuleSet.Resolver(run: run, get: get, resolveWhen: when, env: env)
    }

    func testSubstitutionFillsNumberedHolesAndRefusesMissingOnes() {
        guard case .success(let plan) = resolver(
            run: ["gh", "pr", "view", "$1", "--repo", "$2", "--json", "state"]
        ).plan(arguments: ["142", "hausfold/trill"]) else { return XCTFail("expected a plan") }

        guard case .command(let argv, _, _, _, _) = plan else { return XCTFail("expected a command") }
        XCTAssertEqual(argv, ["gh", "pr", "view", "142", "--repo", "hausfold/trill", "--json", "state"])

        if case .success = resolver(run: ["gh", "pr", "view", "$2"]).plan(arguments: ["142"]) {
            XCTFail("a hole with nothing to fill it must fail loudly — `gh pr view \"\"` would not")
        }
    }

    func testALiteralDollarStaysALiteralDollar() {
        guard case .success(let plan) = resolver(run: ["echo", "$HOME, $0 and 5$"]).plan(arguments: []),
              case .command(let argv, _, _, _, _) = plan
        else { return XCTFail("expected a command") }
        XCTAssertEqual(
            argv[1], "$HOME, $0 and 5$",
            "only $1…$9 are holes: no environment expansion here, and no shell to do one"
        )
    }

    func testURLArgumentsArePercentEncodedIntoTheUnreservedSet() {
        guard case .success(let plan) = resolver(get: "https://example.test/health/$1")
            .plan(arguments: ["a b&c=d/e?f"]),
              case .request(let url, _, _) = plan
        else { return XCTFail("expected a request") }

        XCTAssertEqual(url.absoluteString, "https://example.test/health/a%20b%26c%3Dd%2Fe%3Ff")
        XCTAssertEqual(url.host, "example.test", "an argument can't grow a second host or a query")
    }

    func testPlanRefusesAmbiguousAndNonHTTPResolvers() {
        for broken in [
            resolver(),
            resolver(run: ["gh"], get: "https://example.test"),
            resolver(run: []),
            resolver(run: ["--wat"]),
            resolver(get: "file:///etc/passwd"),
            resolver(get: "not a url at all"),
        ] {
            if case .success = broken.plan(arguments: []) {
                XCTFail("expected a refusal for \(broken)")
            }
        }
    }

    func testACommandPlanCarriesItsWholeEnvironmentAndNothingElse() {
        guard case .success(let plan) = resolver(run: ["gh"], env: ["GH_TOKEN": "t"]).plan(arguments: []),
              case .command(_, let env, let cwd, _, _) = plan
        else { return XCTFail("expected a command") }

        XCTAssertEqual(env["GH_TOKEN"], "t", "a token belongs in the rules file, never on the wire")
        XCTAssertEqual(
            env["PATH"], RuleSet.Resolver.defaultPath,
            "a GUI daemon inherits launchd's PATH, which has no Homebrew in it"
        )
        XCTAssertEqual(env["HOME"], NSHomeDirectory())
        XCTAssertNil(cwd, "no cwd means home — the lane an ask came from may be gone")
    }

    // MARK: - Predicates and durations (pure)

    func testPredicateDefaultsToExitZeroAndTwoHundreds() {
        let empty = RuleSet.Resolver.Predicate()
        XCTAssertTrue(empty.satisfied(exit: 0, stdout: "anything"))
        XCTAssertFalse(empty.satisfied(exit: 1, stdout: ""))
        XCTAssertTrue(empty.satisfied(status: 204, body: ""))
        XCTAssertFalse(empty.satisfied(status: 404, body: ""))
    }

    func testPredicateClausesAreAndNotOr() {
        let merged = RuleSet.Resolver.Predicate(exit: 0, stdout: "MERGED")
        XCTAssertTrue(merged.satisfied(exit: 0, stdout: "  MERGED\n"), "stdout is compared trimmed")
        XCTAssertFalse(merged.satisfied(exit: 0, stdout: "OPEN"))
        XCTAssertFalse(merged.satisfied(exit: 1, stdout: "MERGED"))
        XCTAssertFalse(
            RuleSet.Resolver.Predicate(stdout: "MERGED").satisfied(exit: 0, stdout: "not merged yet"),
            "substring luck must not answer a question — that's what stdoutContains is for"
        )
        XCTAssertTrue(
            RuleSet.Resolver.Predicate(stdoutContains: "MERGED").satisfied(exit: 3, stdout: "state: MERGED")
        )
        XCTAssertFalse(
            RuleSet.Resolver.Predicate(status: 200).satisfied(exit: 0, stdout: ""),
            "an HTTP-only predicate can never be satisfied by a command"
        )
    }

    func testDurationsReadTheWayHumansWriteThem() {
        XCTAssertEqual(RuleSet.Resolver.seconds(from: "45s"), 45)
        XCTAssertEqual(RuleSet.Resolver.seconds(from: "2m"), 120)
        XCTAssertEqual(RuleSet.Resolver.seconds(from: "12h"), 43200)
        XCTAssertEqual(RuleSet.Resolver.seconds(from: "3d"), 259200)
        XCTAssertEqual(RuleSet.Resolver.seconds(from: "90"), 90, "bare seconds still work")
        XCTAssertNil(RuleSet.Resolver.seconds(from: "soon"))
    }

    func testPollingBoundsAreClampedNotTrusted() {
        let hammer = RuleSet.Resolver(run: ["true"], every: 0.1, timeout: 9999, giveUpAfter: 1)
        XCTAssertEqual(hammer.every, RuleSet.Resolver.Bounds.every.lowerBound)
        XCTAssertEqual(hammer.timeout, RuleSet.Resolver.Bounds.timeout.upperBound)
        XCTAssertEqual(hammer.giveUpAfter, RuleSet.Resolver.Bounds.giveUpAfter.lowerBound)
    }

    // MARK: - rules.json

    func testResolversDecodeFromTheDocumentedShape() throws {
        let json = Data("""
        {
          "rules": [],
          "resolvers": {
            "pr-merged": {
              "run": ["gh", "pr", "view", "$1", "--repo", "$2", "--json", "state", "-q", ".state"],
              "resolveWhen": { "stdout": "MERGED" },
              "every": "2m", "timeout": "10s", "giveUpAfter": "12h"
            },
            "endpoint-up": { "get": "https://$1/healthz", "resolveWhen": { "status": 200 } }
          }
        }
        """.utf8)

        let rules = try JSONDecoder.trill.decode(RuleSet.self, from: json)
        let merged = try XCTUnwrap(rules.resolver(named: "pr-merged"))
        XCTAssertEqual(merged.every, 120)
        XCTAssertEqual(merged.timeout, 10)
        XCTAssertEqual(merged.giveUpAfter, 12 * 3600)
        XCTAssertEqual(merged.resolveWhen?.stdout, "MERGED")
        XCTAssertNotNil(rules.resolver(named: "endpoint-up"))
        XCTAssertNil(rules.resolver(named: "not-declared"), "an undeclared name resolves nothing")
    }

    func testAResolverFileWithoutResolversStillLoads() throws {
        let rules = try JSONDecoder.trill.decode(
            RuleSet.self,
            from: Data(#"{"rules":[{"match":{"source":"ads"},"delivery":"drop"}]}"#.utf8)
        )
        XCTAssertEqual(rules.rules.count, 1, "resolvers are additive — an old rules.json must not stop parsing")
        XCTAssertNil(rules.resolvers)
    }

    func testAnUnparseableDurationFailsTheFileRatherThanGuessing() {
        XCTAssertThrowsError(try JSONDecoder.trill.decode(
            RuleSet.self,
            from: Data(#"{"rules":[],"resolvers":{"x":{"run":["true"],"every":"soonish"}}}"#.utf8)
        ), "a typo'd interval must be visible — the watcher keeps the last good rules and logs")
    }

    // MARK: - The runner (real processes, no shell)

    private func outcome(
        run argv: [String], when: RuleSet.Resolver.Predicate? = nil, timeout: TimeInterval = 5
    ) async throws -> ResolverRunner.Outcome {
        let resolver = RuleSet.Resolver(run: argv, resolveWhen: when, timeout: timeout)
        guard case .success(let plan) = resolver.plan(arguments: []) else {
            throw XCTSkip("expected a plan")
        }
        return await ResolverRunner.check(plan)
    }

    func testARealCommandAnswersYesNoOrBroken() async throws {
        let merged = RuleSet.Resolver.Predicate(stdout: "MERGED")
        await XCTAssertEqualAsync(try await outcome(run: ["echo", "MERGED"], when: merged), .resolved)
        await XCTAssertEqualAsync(try await outcome(run: ["echo", "OPEN"], when: merged), .notYet)
        await XCTAssertEqualAsync(try await outcome(run: ["false"]), .notYet, "exit 1 is 'not yet', not 'broken'")

        // The typo case: env answers 127, and reading that as "not yet"
        // would poll a misspelled program until giveUpAfter.
        guard case .failed = try await outcome(run: ["trill-no-such-program-xyz"]) else {
            return XCTFail("an unrunnable resolver must fail, not wait")
        }
    }

    func testTheShellIsNotInvolved() async throws {
        // If anything were parsing a command *line*, this would print "hi"
        // and touch a file. It is one argument to echo, and only that.
        await XCTAssertEqualAsync(
            try await outcome(
                run: ["echo", "hi; touch /tmp/trill-should-not-exist"],
                when: RuleSet.Resolver.Predicate(stdoutContains: "; touch")
            ),
            .resolved
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/trill-should-not-exist"))
    }

    func testASlowCommandIsKilledAndReportedAsBroken() async throws {
        guard case .failed(let reason) = try await outcome(run: ["sleep", "30"], timeout: 1) else {
            return XCTFail("a resolver that hangs must not hold a slot forever")
        }
        XCTAssertTrue(reason.contains("timed out"))
    }

    // MARK: - The ledge on disk

    @MainActor
    func testTheLedgeSurvivesARestartAndForgetsStaleQuestions() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("trill-ledge-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: file) }
        let database = try XCTUnwrap(AppDatabase(url: file))

        var fresh = ask("fresh", key: "k")
        fresh.timestamp = .now
        var stale = ask("stale")
        stale.timestamp = Date(timeIntervalSinceNow: -(BannerQueue.parkedLifetime + 60))

        database.saveLedge([
            AppDatabase.StoredParked(event: stale, coalescedCount: 0),
            AppDatabase.StoredParked(event: fresh, coalescedCount: 4),
        ])

        let restored = database.parkedLedge(maxAge: BannerQueue.parkedLifetime)
        XCTAssertEqual(restored.map(\.event.id), ["fresh"], "a week-old question is not a question any more")
        XCTAssertEqual(restored.first?.coalescedCount, 4)
        XCTAssertEqual(restored.first?.event.key, "k", "the name it answers to has to survive too")

        // The mirror is wholesale: answering the last fin empties the table.
        database.saveLedge([])
        XCTAssertTrue(database.parkedLedge(maxAge: BannerQueue.parkedLifetime).isEmpty)
    }
}

/// `XCTAssertEqual` with an async autoclosure. XCTest's own overload takes a
/// synchronous one, so an `await` inside it doesn't compile.
func XCTAssertEqualAsync<T: Equatable>(
    _ expression: @autoclosure () async throws -> T,
    _ expected: T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        let value = try await expression()
        XCTAssertEqual(value, expected, message, file: file, line: line)
    } catch {
        XCTFail("threw \(error). \(message)", file: file, line: line)
    }
}
