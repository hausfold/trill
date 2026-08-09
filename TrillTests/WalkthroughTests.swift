import XCTest
@testable import Trill

/// The helper panel's walkthrough decides two things that are easy to get
/// silently wrong: when it ends, and which of its two endings it shows. Both
/// are pure, so both are pinned here rather than left to a feel-test — and the
/// second one is a claim about macOS, which trill must not make on a button
/// press it never verified.
final class WalkthroughTests: XCTestCase {
    private func noisy(_ id: String) -> NativeNotificationSettings {
        NotificationSettingsAudit.decode(bundleID: id, flags: 0b01110 | 1 << 25)
    }

    private lazy var worklist = ["com.a", "com.b", "com.c"].map(noisy)

    func testTheCurrentAppIsTheFirstUnfinishedOne() {
        var walk = Walkthrough()
        XCTAssertEqual(walk.current(in: worklist)?.bundleID, "com.a")
        walk.advanced.insert("com.a")
        XCTAssertEqual(walk.current(in: worklist)?.bundleID, "com.b")
    }

    func testFixingTheThirdAppFirstSimplySkipsIt() {
        // The user is free to work the pane in any order — the poll confirms
        // whatever it finds quiet, and the walkthrough must not march them
        // back through an app that's already done.
        var walk = Walkthrough()
        walk.confirmed.insert("com.c")
        XCTAssertEqual(walk.current(in: worklist)?.bundleID, "com.a")
        XCTAssertEqual(walk.remaining(in: worklist), 2)
        XCTAssertEqual(walk.done(in: worklist), 1)
    }

    func testBothRoutesToDoneCount() {
        var walk = Walkthrough()
        walk.confirmed.insert("com.a")
        walk.advanced.insert("com.b")
        XCTAssertTrue(walk.isFinished("com.a"))
        XCTAssertTrue(walk.isFinished("com.b"))
        XCTAssertFalse(walk.isFinished("com.c"))
        XCTAssertEqual(walk.remaining(in: worklist), 1)
    }

    func testTheWalkthroughEndsOnlyWhenNothingIsLeft() {
        var walk = Walkthrough()
        XCTAssertEqual(walk.remaining(in: worklist), 3)
        walk.advanced.formUnion(["com.a", "com.b"])
        XCTAssertEqual(walk.remaining(in: worklist), 1, "two of three is not the end")
        walk.confirmed.insert("com.c")
        XCTAssertEqual(walk.remaining(in: worklist), 0)
    }

    /// The one that matters: trill may only say "macOS has stopped drawing
    /// them" when macOS actually said so. A single app the user marked done
    /// themselves takes that sentence away.
    func testOneUserAdvancedAppMeansMacOSNeverConfirmedIt() {
        var walk = Walkthrough()
        walk.confirmed.formUnion(["com.a", "com.b", "com.c"])
        XCTAssertTrue(walk.everythingWasConfirmed)

        walk.advanced.insert("com.b")
        XCTAssertFalse(
            walk.everythingWasConfirmed,
            "an app trill never verified must not be reported as verified"
        )
    }

    func testAnAppConfirmedTwiceIsStillOneApp() {
        var walk = Walkthrough()
        walk.confirmed.insert("com.a")
        walk.confirmed.insert("com.a")
        XCTAssertEqual(walk.done(in: worklist), 1)
    }

    func testAnEmptyWorklistIsAlreadyFinished() {
        XCTAssertEqual(Walkthrough().remaining(in: []), 0)
        XCTAssertNil(Walkthrough().current(in: []))
    }
}
