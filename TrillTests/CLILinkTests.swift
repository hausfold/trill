import XCTest
@testable import Trill

/// Who owns the name `trill`, decided from what a login shell resolves and
/// what is sitting on the link path — the whole of `ensureCLILink`'s judgement,
/// with the filesystem and the shell taken out of it.
///
/// The three cases this exists to keep apart all look alike from one step back:
/// "something answers `trill`" is the good case when it's another installer and
/// the *ordinary* case when it's the link trill placed last launch, and a file
/// on the path is neither.
@MainActor
final class CLILinkTests: XCTestCase {
    private let link = "/Users/x/.local/bin/trill"

    func testAnotherInstallerOwnsTheName() {
        // nix's bin/trill, a desktop's link at the copy it placed, a cask's
        // binary stanza. Its answer points at the bundle whose permission
        // grants and daemon socket the user actually has; ours would not.
        XCTAssertEqual(
            SystemIntegration.cliLinkPlan(
                resolved: "/run/current-system/sw/bin/trill",
                linkPath: link,
                occupant: .nothing
            ),
            .leaveAlone("/run/current-system/sw/bin/trill")
        )
    }

    func testOurOwnLinkIsNotAnotherInstaller() {
        // Every launch after the first. Resolving to the link we placed means
        // we still own it — reading that as "someone else got here" would make
        // trill stop refreshing a link whose target may have moved.
        XCTAssertEqual(
            SystemIntegration.cliLinkPlan(resolved: link, linkPath: link, occupant: .symlink),
            .place
        )
    }

    func testNothingResolvesAndNothingIsThere() {
        XCTAssertEqual(
            SystemIntegration.cliLinkPlan(resolved: nil, linkPath: link, occupant: .nothing),
            .place
        )
    }

    func testDanglingLinkIsRefreshedNotAbandoned() {
        // A link whose bundle moved resolves to nothing, but the link is still
        // there. `command -v trill` succeeds and every call fails — strictly
        // worse than no link at all — so this must be the case that replaces it.
        XCTAssertEqual(
            SystemIntegration.cliLinkPlan(resolved: nil, linkPath: link, occupant: .symlink),
            .place
        )
    }

    func testRealFileIsNeverClobbered() {
        // Somebody else's tool, or a script the user wrote. trill declines and
        // says so rather than deleting it.
        guard case .refuse(let reason) = SystemIntegration.cliLinkPlan(
            resolved: nil, linkPath: link, occupant: .other
        ) else { return XCTFail("a regular file on the path must not be replaced") }
        XCTAssertTrue(reason.contains(link), "the refusal has to name the path the user must clear")
    }

    func testRealFileOnPathStillDefersToWhoeverAnswers() {
        // Both signals at once, and `leaveAlone` wins: what resolves is the
        // fact that matters, and it is not ours to touch either way.
        XCTAssertEqual(
            SystemIntegration.cliLinkPlan(
                resolved: "/opt/homebrew/bin/trill", linkPath: link, occupant: .other
            ),
            .leaveAlone("/opt/homebrew/bin/trill")
        )
    }

    // MARK: - Which directory the shim goes in

    private let home = "/Users/x"

    func testAConventionalDirectoryIsOnlyUsedWhenItIsActuallyOnPath() {
        // The whole point. ~/.local/bin is the conventional answer and is on
        // no macOS PATH by default; choosing it blind writes a file that
        // exists and a command that never runs.
        XCTAssertEqual(
            SystemIntegration.cliLinkDirectory(
                loginPath: ["/usr/bin", "/Users/x/.local/bin"], home: home
            ).path,
            "/Users/x/.local/bin"
        )
    }

    func testFallsBackToTheConventionalDirectoryWhenPathOffersNothing() {
        // Still placed, so a user who fixes their PATH afterwards finds it
        // already there — but the caller reports `linkedNotOnPath`, not success.
        XCTAssertEqual(
            SystemIntegration.cliLinkDirectory(
                loginPath: ["/usr/bin", "/usr/local/bin"], home: home
            ).path,
            "/Users/x/.local/bin"
        )
    }

    func testNeverWritesIntoADirectoryTrillDoesNotOwn() {
        // /usr/local/bin wants admin; an app that raises an auth prompt at
        // launch to install a convenience is an app people quit.
        XCTAssertEqual(
            SystemIntegration.cliLinkDirectory(
                loginPath: ["/usr/local/bin", "/opt/homebrew/bin"], home: home
            ).path,
            "/Users/x/.local/bin"
        )
    }

    func testNixManagedDirectoriesAreSkippedEvenOnPath() {
        // Generated: a link written into a profile bin is gone at the next
        // rebuild, and misleading until then.
        XCTAssertEqual(
            SystemIntegration.cliLinkDirectory(
                loginPath: ["/etc/profiles/per-user/x/bin", "/Users/x/tools"], home: home
            ).path,
            "/Users/x/tools",
            "a nix profile bin on PATH is not a place to write a link"
        )
    }

    func testTheConventionalDirectoryWinsOverWhateverCameFirst() {
        XCTAssertEqual(
            SystemIntegration.cliLinkDirectory(
                loginPath: ["/Users/x/tools", "/Users/x/bin", "/Users/x/.local/bin"], home: home
            ).path,
            "/Users/x/.local/bin"
        )
    }

    // MARK: - Reading the login shell

    func testNothingResolvingDoesNotShiftThePathUpIntoIt() {
        // The blank line is why the shell prints three lines for two answers:
        // without it an empty `command -v` would leave PATH on line one and
        // trill would report the whole PATH as the resolved binary.
        let (resolved, path) = SystemIntegration.parseShellReading("\n\n/usr/bin:/bin\n")
        XCTAssertNil(resolved)
        XCTAssertEqual(path, ["/usr/bin", "/bin"])
    }

    func testBothAnswersComeBackFromTheOneSpawn() {
        let (resolved, path) = SystemIntegration.parseShellReading(
            "/opt/homebrew/bin/trill\n\n/opt/homebrew/bin:/usr/bin\n"
        )
        XCTAssertEqual(resolved, "/opt/homebrew/bin/trill")
        XCTAssertEqual(path, ["/opt/homebrew/bin", "/usr/bin"])
    }

    func testAShellThatSaidNothingIsNotAnEmptyPath() {
        let (resolved, path) = SystemIntegration.parseShellReading("")
        XCTAssertNil(resolved)
        XCTAssertEqual(path, [], "no reading at all degrades to reporting, never to a wrong claim")
    }

    func testConfigRoundTripsTheSwitch() {
        // A switch that writes but doesn't read reverts on the next reload.
        var config = AppConfig()
        config.cliLink = false
        XCTAssertEqual(AppConfig(json: config.json).cliLink, false)
        XCTAssertTrue(AppConfig().cliLink, "a CLI you have to opt into is a CLI nobody has")
    }
}
