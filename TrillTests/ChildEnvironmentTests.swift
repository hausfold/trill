import XCTest
@testable import Trill

/// What trill hands a process it spawns.
///
/// The bug behind these: this desktop relaunches Trill.app from a rebuild's
/// activation script, through `sudo --user=…`, and macOS keeps `HOME` across
/// that sudo — so the app runs as the user with `/var/root` in its
/// environment. trill's own reads are immune (they ask the password database,
/// not the variable), but `scruff focus` inherited it, couldn't reach a
/// registry under `/var/root/.cache`, and exited in five milliseconds. The
/// banner click did nothing, said nothing, and left nothing to find.
final class ChildEnvironmentTests: XCTestCase {
    func testHomeIsTheUsersOwnEvenWhenTrillInheritedRoots() {
        let child = SystemIntegration.childEnvironment(
            inheriting: ["HOME": "/var/root", "PATH": "/usr/bin:/bin"],
            home: "/Users/someone"
        )
        XCTAssertEqual(child["HOME"], "/Users/someone", "a child must never be told root's home")
    }

    func testHomeIsSuppliedWhenTheEnvironmentCarriesNone() {
        let child = SystemIntegration.childEnvironment(inheriting: [:], home: "/Users/someone")
        XCTAssertEqual(child["HOME"], "/Users/someone")
    }

    /// Everything else rides along: scruff shells out to `git` and `gh` and
    /// execs the desktop's own hooks, so inventing a PATH here would be
    /// trill guessing at a machine it knows nothing about.
    func testEverythingElsePassesThrough() {
        let child = SystemIntegration.childEnvironment(
            inheriting: ["PATH": "/nix/bin:/usr/bin", "SSH_AUTH_SOCK": "/tmp/sock"],
            home: "/Users/someone"
        )
        XCTAssertEqual(child["PATH"], "/nix/bin:/usr/bin")
        XCTAssertEqual(child["SSH_AUTH_SOCK"], "/tmp/sock")
    }

    /// The live one, on whatever machine is running the suite: the default
    /// home comes from the password database, so it is a real directory that
    /// belongs to the user running the tests — never the `HOME` variable.
    func testDefaultHomeIsTheAccountsOwn() {
        let child = SystemIntegration.childEnvironment(inheriting: ["HOME": "/var/root"])
        XCTAssertEqual(child["HOME"], FileManager.default.homeDirectoryForCurrentUser.path)
        XCTAssertNotEqual(child["HOME"], "/var/root")
    }
}
