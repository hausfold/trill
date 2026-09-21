import XCTest
@testable import Trill

/// `trill --version` used to hang forever, and so did every other token trill
/// did not recognise (#67). Nothing was slow and nothing was unreachable: the
/// binary has two personalities, and the argument never reached the one that
/// could refuse it. `TrillMain` routed only a token already in
/// its own list of verbs; everything else fell through to `NSApplication.run()`
/// and became a second daemon in the foreground of whoever's shell, printing
/// nothing and never returning. One of them held an ssh session open for 21
/// hours, and `--version` is the first thing an install check reaches for.
///
/// These pin both halves of the fix: that an argument is a command, and that a
/// command trill cannot parse is *bad usage* rather than a refusal.
final class UnknownVerbTests: XCTestCase {

    /// The four from the issue's table, verbatim.
    private let unknown = ["--version", "-v", "version", "notaverb"]

    func testAnUnrecognisedTokenRefusesInsteadOfHanging() {
        for token in unknown {
            XCTAssertEqual(
                TrillCLI.run(arguments: [token]), 1,
                "`trill \(token)` has to come back, and 1 is bad usage"
            )
        }
    }

    func testHelpStillAnswersZero() {
        for token in ["help", "--help", "-h"] {
            XCTAssertEqual(TrillCLI.run(arguments: [token]), 0)
        }
    }

    /// The shipped skill promised exit 3 for "a verb this daemon doesn't know",
    /// which is what made the hang read as a missing refusal rather than a
    /// missing route. The table is the contract an agent reads; keep it honest.
    func testTheShippedSkillNoLongerPromisesThreeForAnUnknownVerb() {
        guard let skill = TrillCLI.EmbeddedSkills.all.first(where: { $0.name == "trill" }) else {
            return XCTFail("the trill skill is not embedded")
        }
        XCTAssertFalse(
            skill.body.contains("a verb this daemon doesn't know"),
            "exit 3's row still claims the code this fix moved to 1"
        )
    }
}
