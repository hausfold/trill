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

    // MARK: - Apps macOS lists no row for

    /// An app named in `rules.json` that System Settings doesn't list (bit 7 —
    /// `com.apple.SoftwareUpdateNotification` is the one a real rules file hits
    /// first). There's no click to make, so the step exists only to be stepped
    /// past.
    private func unlisted(_ id: String) -> NativeNotificationSettings {
        NotificationSettingsAudit.decode(bundleID: id, flags: 0b01110 | 1 << 7 | 1 << 25)
    }

    func testASkippedAppStillMovesTheWalkthroughOn() {
        var walk = Walkthrough()
        walk.skipped.insert("com.a")
        XCTAssertTrue(walk.isFinished("com.a"))
        XCTAssertEqual(walk.current(in: worklist)?.bundleID, "com.b")
        XCTAssertEqual(walk.done(in: worklist), 1)
    }

    /// The point of the third set: a skipped app was never fixed by anyone, so
    /// it must take the "macOS has stopped drawing them" line away exactly as
    /// a user-advanced one does.
    func testASkippedAppIsNotAConfirmation() {
        var walk = Walkthrough()
        walk.confirmed.formUnion(["com.a", "com.b"])
        walk.skipped.insert("com.c")
        XCTAssertEqual(walk.remaining(in: worklist), 0)
        XCTAssertFalse(
            walk.everythingWasConfirmed,
            "an app macOS gave no switch for is still drawing — it is not confirmed quiet"
        )
    }

    func testAnUnlistedAppIsStillNoisy() {
        // It stays in the worklist: having no row doesn't make it quiet, and
        // dropping it would be trill hiding a duplicate banner it can see.
        let finding = unlisted("com.apple.SoftwareUpdateNotification")
        XCTAssertFalse(finding.hasSettingsRow)
        XCTAssertTrue(finding.isNoisy)
    }

    // MARK: - The closing line

    func testTheClosingLineOnlyCreditsMacOSWhenMacOSConfirmed() {
        XCTAssertTrue(
            OnboardingAssistantView.closingLine(confirmed: true, unfixable: 0, total: 3)
                .contains("macOS has stopped drawing them")
        )
        XCTAssertFalse(
            OnboardingAssistantView.closingLine(confirmed: false, unfixable: 0, total: 3)
                .contains("macOS has stopped")
        )
    }

    func testTheClosingLineNamesWhatMacOSKeptDrawing() {
        let some = OnboardingAssistantView.closingLine(confirmed: false, unfixable: 1, total: 3)
        XCTAssertTrue(some.contains("one of them"))
        XCTAssertTrue(some.contains("the rest"))

        let many = OnboardingAssistantView.closingLine(confirmed: false, unfixable: 2, total: 3)
        XCTAssertTrue(many.contains("2 of them"))
    }

    /// A worklist that was *entirely* unfixable has no "rest" to hand over,
    /// and a closing card claiming one would be taking credit for a
    /// walkthrough in which nothing changed.
    func testTheClosingLinePromisesNoRestWhenThereIsNone() {
        for total in 1...2 {
            let line = OnboardingAssistantView.closingLine(
                confirmed: false, unfixable: total, total: total
            )
            XCTAssertFalse(line.contains("the rest"), "total \(total)")
            XCTAssertTrue(line.contains("no row, no switch"), "total \(total)")
        }
    }
}
