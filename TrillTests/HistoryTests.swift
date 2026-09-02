import XCTest
@testable import Trill

/// `trill history` — the read half of `send`, and the verb that made trill
/// scriptable in both directions.
///
/// Everything here is the pure half: the flags become a `HistoryQuery`, the
/// query picks rows, and the wire carries them. No socket, no database, no
/// display — the daemon side is a bounded fetch and `HistoryQuery.filter`, so
/// this is where "which rows answer that question" is actually settled.
final class HistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_756_000_000)

    private func at(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

    private func entry(
        id: String = UUID().uuidString,
        source: String = "ci",
        title: String = "something happened",
        body: String? = nil,
        thread: String? = nil,
        kind: NotificationEvent.Kind = .note,
        decision: String = "banner",
        read: Bool = true,
        at offset: TimeInterval = 0
    ) -> InboxEntry {
        InboxEntry(
            event: NotificationEvent(
                id: id, source: source, timestamp: at(offset), title: title,
                body: body, thread: thread, kind: kind
            ),
            decision: decision,
            readAt: read ? at(offset) : nil
        )
    }

    // MARK: - Parsing

    func testABareHistoryAsksForTheDefaultQuery() {
        guard case .success(let invocation) = TrillCLI.parseHistory([], now: now) else {
            return XCTFail("`trill history` with no flags must parse")
        }
        XCTAssertEqual(invocation.request.verb, "history")
        XCTAssertFalse(invocation.json, "human output is the default; --json is the ask")
        let query = invocation.request.history
        XCTAssertEqual(query?.limit, HistoryQuery.defaultLimit)
        XCTAssertNil(query?.source)
        XCTAssertNil(query?.kind)
        XCTAssertNil(query?.since)
        XCTAssertNil(query?.search)
        XCTAssertEqual(
            query?.unreadOnly, false,
            "\"what fired\" and \"what did I miss\" are different questions — this verb answers the first unless asked"
        )
    }

    func testEveryFilterReachesTheQuery() {
        guard case .success(let invocation) = TrillCLI.parseHistory([
            "--limit", "5", "--source", "Deploy", "--kind", "fault", "--unread",
            "--since", "2h", "--search", "preview promoted", "--json",
        ], now: now) else {
            return XCTFail("the full flag set must parse")
        }
        let query = invocation.request.history
        XCTAssertTrue(invocation.json)
        XCTAssertEqual(query?.limit, 5)
        XCTAssertEqual(query?.source, "Deploy")
        XCTAssertEqual(query?.kind, .fault)
        XCTAssertEqual(query?.unreadOnly, true)
        XCTAssertEqual(query?.search, "preview promoted")
        XCTAssertEqual(
            query?.since, now.addingTimeInterval(-7200),
            "--since resolves against the clock HERE, so the window is the one the caller meant"
        )
    }

    func testTheFlagsThatAreRefusedRatherThanGuessedAt() {
        let refusals: [[String]] = [
            ["--limit", "0"],
            ["--limit", "1001"], // past the scan; a promise this verb can't keep
            ["--limit", "lots"],
            ["--limit"],
            ["--kind", "loud"],
            ["--source", ""],
            ["--search", "   "],
            ["--since", "yesterday"],
            ["--since", "-2h"], // a window in the future; no row can be in it
            ["--wat"],
        ]
        for args in refusals {
            if case .success = TrillCLI.parseHistory(args, now: now) {
                XCTFail("\(args) should not parse")
            }
        }
    }

    func testSinceTakesADurationOrAnAbsoluteInstant() {
        XCTAssertEqual(HistoryQuery.instant("30m", now: now), now.addingTimeInterval(-1800))
        XCTAssertEqual(HistoryQuery.instant("7d", now: now), now.addingTimeInterval(-604_800))
        XCTAssertEqual(HistoryQuery.instant("90", now: now), now.addingTimeInterval(-90))
        XCTAssertEqual(
            HistoryQuery.instant("2025-08-24T01:46:40Z", now: now), now,
            "a script that already holds a timestamp shouldn't have to turn it into a duration"
        )
        XCTAssertNil(HistoryQuery.instant("", now: now))
        XCTAssertNil(HistoryQuery.instant("soon", now: now))
    }

    // MARK: - Filtering

    func testSourceMatchesTheWayRulesMatchIt() {
        let rows = [entry(source: "Deploy"), entry(source: "ci"), entry(source: "deploy")]
        var query = HistoryQuery()
        query.source = "DEPLOY"
        XCTAssertEqual(
            query.filter(rows).count, 2,
            "case-insensitive, like rules.json — one spelling of \"same source\" across the app"
        )
    }

    func testKindUnreadAndSinceEachNarrow() {
        let rows = [
            entry(kind: .ask, read: false, at: 100),
            entry(kind: .ask, read: true, at: 50),
            entry(kind: .note, read: false, at: 10),
        ]

        var byKind = HistoryQuery()
        byKind.kind = .ask
        XCTAssertEqual(byKind.filter(rows).count, 2)

        var unread = HistoryQuery()
        unread.unreadOnly = true
        XCTAssertEqual(unread.filter(rows).count, 2)

        var recent = HistoryQuery()
        recent.since = at(60)
        XCTAssertEqual(recent.filter(rows).count, 1, "--since is a floor, not a window")
    }

    func testSearchIsTheInboxSearchAndTermsAreANDed() {
        let rows = [
            entry(title: "deploy failed", body: "staging"),
            entry(title: "deploy landed", body: "production"),
        ]
        var query = HistoryQuery()
        query.search = "deploy production"
        let found = query.filter(rows)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.event.title, "deploy landed")
    }

    func testLimitTakesTheNewestAndKeepsTheOrderItArrivedIn() {
        // Newest first, the order every database read arrives in.
        let rows = (0..<10).map { entry(id: "e\($0)", at: TimeInterval(-$0)) }
        var query = HistoryQuery()
        query.limit = 3
        let found = query.filter(rows)
        XCTAssertEqual(found.map(\.id), ["e0", "e1", "e2"])
    }

    func testThreadsAreNotFolded() {
        let rows = (0..<3).map { entry(id: "t\($0)", thread: "pr-142", at: TimeInterval(-$0)) }
        XCTAssertEqual(
            HistoryQuery().filter(rows).count, 3,
            "the window folds a thread because you read it with your eyes; a script wants the three"
        )
    }

    func testAHandWrittenQueryIsClampedBeforeItRuns() {
        var wild = HistoryQuery()
        wild.limit = 1_000_000
        wild.search = String(repeating: "x", count: 5000)
        let safe = wild.clamped()
        XCTAssertEqual(safe.limit, HistoryQuery.scanLimit)
        XCTAssertEqual(safe.search?.count, HistoryQuery.searchLimit)

        var tiny = HistoryQuery()
        tiny.limit = 0
        XCTAssertEqual(tiny.clamped().limit, 1)
    }

    // MARK: - The wire

    func testTheDaemonTakesAHistoryRequestAndClampsIt() {
        let line = Data(#"{"v":1,"verb":"history","history":{"limit":9999,"unreadOnly":true}}"#.utf8)
        guard case .history(let query) = SocketProvider.handle(line: line) else {
            return XCTFail("the daemon must understand the history verb")
        }
        XCTAssertEqual(query.limit, HistoryQuery.scanLimit)
        XCTAssertTrue(query.unreadOnly)
    }

    func testAHistoryRequestWithNoQueryIsTheDefaultOne() {
        let line = Data(#"{"v":1,"verb":"history"}"#.utf8)
        XCTAssertEqual(
            SocketProvider.handle(line: line), .history(HistoryQuery()),
            "an omitted query object means the same as an empty one — `trill history` with no flags"
        )
    }

    func testARowRoundTripsBackIntoSomethingSendWouldTake() throws {
        let row = entry(id: "abc", source: "deploy", title: "Deploy landed", read: false)
        let encoded = try JSONEncoder.trill.encode([row])
        let decoded = try JSONDecoder.trill.decode([InboxEntry].self, from: encoded)
        XCTAssertEqual(decoded, [row])

        // The event half is what `trill send --json` reads off stdin. That is
        // the whole "send implies read" test: the verb hands back the shape the
        // write verb took, rather than a summary of it.
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
        let object = try XCTUnwrap(objects.first)
        let eventJSON = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["event"]))
        let event = try JSONDecoder.trill.decode(NotificationEvent.self, from: eventJSON)
        XCTAssertEqual(event.id, "abc")
        XCTAssertEqual(event.title, "Deploy landed")
        XCTAssertNil(
            object["readAt"], "unread is an absent readAt, and that is what a jq consumer branches on"
        )
    }

    // MARK: - End to end, over a real socket and a real database

    /// The claim of the verb, proved the way `ask` proves its own: a caller
    /// writes one line to an actual unix socket and the rows come back down it.
    /// Everything above this line is the decision; this is the delivery.
    func testTheRowsComeBackDownTheSocket() async throws {
        let path = Self.temporarySocketPath()
        defer { unlink(path) }
        let row = entry(id: "abc", source: "deploy", title: "Deploy landed", read: false)
        let provider = SocketProvider(path: path, history: { query, done in
            XCTAssertEqual(query.limit, 5, "the query the CLI parsed is the query the daemon runs")
            done(HistoryPage(entries: [row], scanned: 1))
        })
        let stream = await provider.events()
        // Held to the end of the test: the stream owns the server, and letting
        // it go would close the socket out from under the caller.
        defer { withExtendedLifetime(stream) {} }

        let fd = try Self.connect(to: path)
        defer { close(fd) }
        try Self.write(
            Data(#"{"v":1,"verb":"history","history":{"limit":5}}"#.utf8) + Data([0x0A]), to: fd
        )

        let reply = try XCTUnwrap(Self.readLine(from: fd))
        let response = try JSONDecoder.trill.decode(SocketProvider.Response.self, from: reply)
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.history, [row])
        XCTAssertEqual(response.scanned, 1)
        XCTAssertNil(response.historyUnavailable)
    }

    /// History is a switch, so "nothing fired" and "trill wasn't writing any
    /// of it down" are different answers — the same third verdict `doctor` has.
    /// An empty list here would report a night trill never recorded as a quiet
    /// one, which is the bug this repo has already shipped once elsewhere.
    func testHistoryOffAnswersCantTellRatherThanNothing() async throws {
        let path = Self.temporarySocketPath()
        defer { unlink(path) }
        // The default injection: a provider with no store answers nil.
        let provider = SocketProvider(path: path)
        let stream = await provider.events()
        defer { withExtendedLifetime(stream) {} }

        let fd = try Self.connect(to: path)
        defer { close(fd) }
        try Self.write(Data(#"{"v":1,"verb":"history"}"#.utf8) + Data([0x0A]), to: fd)

        let reply = try XCTUnwrap(Self.readLine(from: fd))
        let response = try JSONDecoder.trill.decode(SocketProvider.Response.self, from: reply)
        XCTAssertTrue(response.ok, "the daemon is fine — it just has nothing written down")
        XCTAssertNil(response.history, "not an empty list; there is no list")
        XCTAssertNotNil(response.historyUnavailable)
        XCTAssertTrue(
            response.historyUnavailable?.contains("persistHistory") ?? false,
            "name the switch, so the reason is actionable rather than a shrug"
        )
    }

    /// The daemon's half, over the real store: the same bounded fetch the
    /// inbox window uses, then the pure filter. If these two ever read
    /// different rows, one question asked two ways gets two answers.
    func testTheFetchTheWindowUsesFeedsTheFilter() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-\(UUID().uuidString)")
            .appendingPathComponent("trill.db")
        let database = try XCTUnwrap(AppDatabase(url: file))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

        database.insert(
            NotificationEvent(id: "shown", source: "deploy", timestamp: at(30), title: "Deploy landed",
                              kind: .done),
            decision: .banner(.primary), now: at(30)
        )
        database.insert(
            NotificationEvent(id: "quiet", source: "slack", timestamp: at(20), title: "someone said hi",
                              kind: .chat),
            decision: .inboxOnly, now: at(20)
        )

        let fetched = database.recent(limit: HistoryQuery.scanLimit)
        XCTAssertEqual(fetched.map(\.id), ["shown", "quiet"], "newest first, the order the verb keeps")

        var unread = HistoryQuery()
        unread.unreadOnly = true
        XCTAssertEqual(
            unread.filter(fetched).map(\.id), ["quiet"],
            "a banner drawn at somebody is read on the way in; what was held back is not"
        )

        var recent = HistoryQuery()
        recent.since = at(25)
        XCTAssertEqual(database.events(since: at(25), limit: HistoryQuery.scanLimit).map(\.id), ["shown"])
        XCTAssertEqual(recent.filter(fetched).map(\.id), ["shown"])
    }

    // MARK: - Socket harness

    private static func temporarySocketPath() -> String {
        // Short, because sun_path is 104 bytes and macOS's temp directory is
        // most of that already.
        "/tmp/trill-hist-\(UUID().uuidString.prefix(8)).sock"
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

    // MARK: - Rendering

    func testAHumanRowSaysWhenWhatAndWhetherItWasEverSeen() {
        let unread = TrillCLI.historyLine(
            entry(source: "deploy", title: "Deploy landed", kind: .done, decision: "inbox", read: false),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertTrue(unread.contains("•"), "the dot means trill never put it in front of anybody")
        XCTAssertTrue(unread.contains("done"))
        XCTAssertTrue(unread.contains("inbox"))
        XCTAssertTrue(unread.contains("deploy"))
        XCTAssertTrue(unread.hasSuffix("Deploy landed"))

        let seen = TrillCLI.historyLine(
            entry(title: "Deploy landed", read: true), timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertFalse(seen.contains("•"))
    }

    func testTheExitCodeSeparatesQuietFromBlind() {
        XCTAssertEqual(
            TrillCLI.renderHistory(SocketProvider.Response(ok: true, history: []), json: true), 0,
            "nothing matched is an answer, and 0 is what an answer exits"
        )
        XCTAssertEqual(
            TrillCLI.renderHistory(
                SocketProvider.Response(ok: true, historyUnavailable: "history is off"), json: true
            ),
            5,
            "5 is trill's \"can't tell\" — the same verdict doctor has, and never 0"
        )
    }

    func testALongSourceIsNeverCut() {
        let line = TrillCLI.historyLine(
            entry(source: "com.tinyspeck.slackmacgap", title: "msg"),
            timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertTrue(
            line.contains("com.tinyspeck.slackmacgap"),
            "a truncated source is a row you can't match against rules.json"
        )
    }
}
