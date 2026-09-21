import XCTest
@testable import Trill

/// `TrillMain.launch(for:)` — the one decision the process entry point makes.
///
/// It is not "is this a verb": `TrillCLI` owns that, and answers a token it
/// does not know with exit 1. It is "did a person type this at all", because
/// before #67 the answer to that was never asked. Anything outside
/// `TrillCLI.subcommands` fell through to `NSApplication.run()`, so a mistyped
/// verb at a shell started a second compositor — one that never even gets the
/// socket (`SocketServer.startLocked` throws on the live one), so it sits
/// mute, reaching nothing, exiting never.
///
/// `main()` itself can't be tested — it ends in `exit` or `run()` — so the
/// decision is pure and this reads it.
final class LaunchDispatchTests: XCTestCase {
    func testNoArgumentsIsTheDaemon() {
        XCTAssertEqual(TrillMain.launch(for: []), .daemon, "Trill.app launched normally")
    }

    /// The bug, in the shapes a person actually types — including the three
    /// that a *generalised* allowlist would swallow. `-Version`, `-Verbose`
    /// and `-Help` are the reason `isLauncherArgument` matches literal
    /// prefixes instead of "a dash then a capitalised word": under that rule
    /// all three read as macOS's and hang, which is #67 again wearing a
    /// capital letter.
    func testAThingAPersonTypedReachesTheCLIAndNeverTheDaemon() {
        let typed = [
            "version", "--version", "-v", "-V", "--ver", "sedn", "Send", "SEND",
            "-Version", "-Verbose", "-Help", "-VeryLongThingWithCaps",
        ]
        for token in typed {
            XCTAssertEqual(
                TrillMain.launch(for: [token]), .cli,
                "`\(token)` is a person's word — the CLI answers or refuses it, never a second compositor"
            )
        }
    }

    /// Declared verbs go the same way, which is the point: routing does not
    /// consult `subcommands`, so a verb added to `TrillCLI.run` and forgotten
    /// in the catalogue still reaches its case.
    func testEveryDeclaredSubcommandReachesTheCLI() {
        for verb in TrillCLI.subcommands {
            XCTAssertEqual(TrillMain.launch(for: [verb, "--title", "x"]), .cli)
        }
    }

    /// …and the arguments that are not a person's, which must still launch.
    /// Refusing one of these is a compositor that never starts, which is
    /// worse than the bug above — so they are tested from the same file.
    func testTheLaunchersOwnArgumentsStillStartTheDaemon() {
        let injected = [
            "-psn_0_12345",                    // LaunchServices
            "-NSDocumentRevisionsDebugMode",   // Xcode scheme Run
            "-ApplePersistenceIgnoreState",
            "-NSTreatUnknownArgumentsAsOpen",
        ]
        for argument in injected {
            XCTAssertEqual(
                TrillMain.launch(for: [argument, "YES"]), .daemon,
                "\(argument) is macOS's, not a typo"
            )
        }
    }

    /// The launch this test is *running inside*. `TrillTests` is app-hosted
    /// (`TEST_HOST` in the project), so the process reading this line was
    /// started by XCTest the way LaunchServices starts the daemon — which
    /// makes its own argv the one sample of a real launch no hand-written
    /// list can go stale against. If Xcode ever passes something outside
    /// `launcherPrefixes`, this fails here rather than in somebody's
    /// `open -g`.
    ///
    /// It is a weaker assertion than it looks from the outside and a stronger
    /// one from in here: an argument treated as a person's would have exited
    /// the host before XCTest loaded a single test, so the suite could not
    /// report the failure at all — it would report nothing.
    func testTheLaunchThisTestIsRunningInsideIsOneOfThem() {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        XCTAssertEqual(
            TrillMain.launch(for: arguments), .daemon,
            "an app-hosted test run is a daemon launch; XCTest passed \(arguments)"
        )
    }

    /// `subcommands` no longer routes anything — it is what `help` lists, so
    /// a verb absent from it is one nothing tells a caller about. Checked
    /// against the nine `TrillCLI.run` answers today, by hand: nothing here
    /// can see a tenth being added.
    func testEveryVerbRunAnswersTodayIsAlsoDiscoverable() {
        for verb in ["send", "ask", "ping", "doctor", "inbox", "history", "resolve", "report", "skill"] {
            XCTAssertTrue(
                TrillCLI.subcommands.contains(verb),
                "\(verb) has a case in TrillCLI.run but `trill help` would not list it"
            )
        }
    }
}
