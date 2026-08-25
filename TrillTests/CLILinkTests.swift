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
                occupant: .nothing,
                resolvedRunsThisBundle: false
            ),
            .leaveAlone("/run/current-system/sw/bin/trill")
        )
    }

    func testOurOwnLinkIsNotAnotherInstaller() {
        // Every launch after the first. Resolving to the link we placed means
        // we still own it — reading that as "someone else got here" would make
        // trill stop refreshing a link whose target may have moved.
        XCTAssertEqual(
            SystemIntegration.cliLinkPlan(
                resolved: link, linkPath: link, occupant: .symlink, resolvedRunsThisBundle: true
            ),
            .place
        )
    }

    func testOurOwnLinkUnderAnotherNameIsNotAStranger() {
        // trill linked ~/bin/trill last launch; the user has since put
        // ~/.local/bin on PATH, so the directory this code prefers moved. What
        // resolves is still trill's own file pointing at this very bundle, and
        // calling that "installed by something else" names our file a stranger's.
        XCTAssertEqual(
            SystemIntegration.cliLinkPlan(
                resolved: "/Users/x/bin/trill", linkPath: link,
                occupant: .nothing, resolvedRunsThisBundle: true
            ),
            .alreadyOurs("/Users/x/bin/trill")
        )
    }

    func testNothingResolvesAndNothingIsThere() {
        XCTAssertEqual(
            SystemIntegration.cliLinkPlan(
                resolved: nil, linkPath: link, occupant: .nothing, resolvedRunsThisBundle: false
            ),
            .place
        )
    }

    func testDanglingLinkIsRefreshedNotAbandoned() {
        // A link whose bundle moved resolves to nothing, but the link is still
        // there. `command -v trill` succeeds and every call fails — strictly
        // worse than no link at all — so this must be the case that replaces it.
        XCTAssertEqual(
            SystemIntegration.cliLinkPlan(
                resolved: nil, linkPath: link, occupant: .symlink, resolvedRunsThisBundle: false
            ),
            .place
        )
    }

    func testRealFileIsNeverClobbered() {
        // Somebody else's tool, or a script the user wrote. trill declines and
        // says so rather than deleting it.
        guard case .refuse(let reason) = SystemIntegration.cliLinkPlan(
            resolved: nil, linkPath: link, occupant: .other, resolvedRunsThisBundle: false
        ) else { return XCTFail("a regular file on the path must not be replaced") }
        XCTAssertTrue(reason.contains(link), "the refusal has to name the path the user must clear")
    }

    func testRealFileOnPathStillDefersToWhoeverAnswers() {
        // Both signals at once, and `leaveAlone` wins: what resolves is the
        // fact that matters, and it is not ours to touch either way.
        XCTAssertEqual(
            SystemIntegration.cliLinkPlan(
                resolved: "/opt/homebrew/bin/trill", linkPath: link,
                occupant: .other, resolvedRunsThisBundle: false
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

    func testNixProfileBinsUnderHomeAreSkipped() {
        // The exclusion that does real work. ~/.nix-profile/bin passes the
        // home test and is a symlink chain into the read-only store, so a link
        // written there fails outright — and would be gone at the next rebuild
        // if it didn't. (/etc/profiles/… and /nix/store never reach this test:
        // the home check already excludes them, which is why spelling THOSE
        // out would be dead code.)
        XCTAssertEqual(
            SystemIntegration.cliLinkDirectory(
                loginPath: ["/Users/x/.nix-profile/bin", "/Users/x/tools"], home: home
            ).path,
            "/Users/x/tools"
        )
        XCTAssertEqual(
            SystemIntegration.cliLinkDirectory(
                loginPath: ["/Users/x/.local/state/nix/profile/bin"], home: home
            ).path,
            "/Users/x/.local/bin",
            "a PATH made only of profile bins offers nothing writable"
        )
    }

    func testAProfileBinIsNotConfusedWithTheConventionalDirectory() {
        // ~/.local/state/nix/profile/bin and ~/.local/bin share a prefix; the
        // filter must not take the second for the first.
        XCTAssertEqual(
            SystemIntegration.cliLinkDirectory(
                loginPath: ["/Users/x/.local/state/nix/profile/bin", "/Users/x/.local/bin"],
                home: home
            ).path,
            "/Users/x/.local/bin"
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

    /// The shell prints:  __trill_cli__ / <answer or nothing> / __trill_path__ / <PATH>
    private func reading(command: String, path: String, noise: String = "") -> String {
        noise + "__trill_cli__\n" + command + "__trill_path__\n" + path + "\n"
    }

    func testAnRcFileBannerIsNotMistakenForAnInstalledBinary() {
        // The bug the sentinels exist for. A login shell sources .zprofile /
        // .zlogin, and those routinely print — a version-manager banner, a
        // greeting. Read off fixed line numbers, one line of that becomes
        // `resolved`, the caller sees a path that isn't ours, and trill
        // silently decides someone else owns the name — telling the user
        // "`trill` is already installed by something else — Welcome back!".
        let (resolved, path) = SystemIntegration.parseShellReading(
            reading(command: "", path: "/usr/bin:/bin", noise: "Welcome back!\nnvm: v20\n")
        )
        XCTAssertNil(resolved)
        XCTAssertEqual(path, ["/usr/bin", "/bin"])
    }

    func testNothingResolvingIsToldFromARealAnswer() {
        let (resolved, path) = SystemIntegration.parseShellReading(
            reading(command: "", path: "/usr/bin")
        )
        XCTAssertNil(resolved)
        XCTAssertEqual(path, ["/usr/bin"])
    }

    func testBothAnswersComeBackFromTheOneSpawn() {
        let (resolved, path) = SystemIntegration.parseShellReading(
            reading(command: "/opt/homebrew/bin/trill\n", path: "/opt/homebrew/bin:/usr/bin")
        )
        XCTAssertEqual(resolved, "/opt/homebrew/bin/trill")
        XCTAssertEqual(path, ["/opt/homebrew/bin", "/usr/bin"])
    }

    func testAShellThatSaidNothingIsNotAnEmptyPath() {
        // What a killed probe leaves behind: the deadline terminated the shell
        // before it printed anything, so there are no sentinels to find.
        let (resolved, path) = SystemIntegration.parseShellReading("")
        XCTAssertNil(resolved)
        XCTAssertEqual(path, [], "no reading at all degrades to reporting, never to a wrong claim")
    }

    func testATruncatedReadingDoesNotInventAPath() {
        // Killed after the first sentinel: an answer started and never came.
        let (resolved, path) = SystemIntegration.parseShellReading("__trill_cli__\n")
        XCTAssertNil(resolved)
        XCTAssertEqual(path, [])
    }

    func testConfigRoundTripsTheSwitch() {
        // A switch that writes but doesn't read reverts on the next reload.
        var config = AppConfig()
        config.cliLink = false
        XCTAssertEqual(AppConfig(json: config.json).cliLink, false)
        XCTAssertTrue(AppConfig().cliLink, "a CLI you have to opt into is a CLI nobody has")
    }
}
