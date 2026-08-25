import XCTest
@testable import Trill

/// The screen-share shyness decision, as a pure function of one reading.
///
/// Every geometry here is measured, not invented: on macOS 26.5 (2026-08-25,
/// this Mac) the in-use indicator is a 28×28 window at the cursor level whose
/// top-right corner sits 3pt inside the display's, and the arrow cursor is a
/// 28×40 window at the same level. Those two are what the classifier has to
/// tell apart.
final class ScreenWatchTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let external = CGRect(x: 1512, y: 0, width: 2560, height: 1440)

    private func indicator(on display: CGRect) -> ScreenWatchSnapshot.Window {
        ScreenWatchSnapshot.Window(
            level: ScreenWatch.indicatorLevel,
            frame: CGRect(x: display.maxX - 31, y: display.minY + 3, width: 28, height: 28),
            onScreen: true
        )
    }

    private let cursor = ScreenWatchSnapshot.Window(
        level: ScreenWatch.indicatorLevel,
        frame: CGRect(x: 861, y: 573, width: 28, height: 40),
        onScreen: true
    )

    func testAnEmptyReadingIsClear() {
        XCTAssertEqual(ScreenWatch.evaluate(ScreenWatchSnapshot()), .clear)
        XCTAssertFalse(ScreenWatch.clear.isWatched)
    }

    func testTheInUseIndicatorMeansWatched() {
        let snapshot = ScreenWatchSnapshot(
            windows: [cursor, indicator(on: laptop)], displays: [laptop], mirroring: false
        )
        XCTAssertEqual(ScreenWatch.evaluate(snapshot), .indicator)
        XCTAssertTrue(ScreenWatch.evaluate(snapshot).isWatched)
    }

    func testTheCursorAloneIsNotAnIndicator() {
        let snapshot = ScreenWatchSnapshot(windows: [cursor], displays: [laptop], mirroring: false)
        XCTAssertEqual(ScreenWatch.evaluate(snapshot), .clear,
                       "the cursor rides the same window level and must not read as an audience")
    }

    func testTheIndicatorCountsOnASecondDisplayToo() {
        let snapshot = ScreenWatchSnapshot(
            windows: [indicator(on: external)], displays: [laptop, external], mirroring: false
        )
        XCTAssertEqual(ScreenWatch.evaluate(snapshot), .indicator)
    }

    func testASquareWindowAwayFromTheCornerIsIgnored() {
        let middle = ScreenWatchSnapshot.Window(
            level: ScreenWatch.indicatorLevel,
            frame: CGRect(x: 700, y: 400, width: 28, height: 28),
            onScreen: true
        )
        let snapshot = ScreenWatchSnapshot(windows: [middle], displays: [laptop], mirroring: false)
        XCTAssertEqual(ScreenWatch.evaluate(snapshot), .clear)
    }

    func testAnOffScreenIndicatorIsIgnored() {
        var stale = indicator(on: laptop)
        stale.onScreen = false
        let snapshot = ScreenWatchSnapshot(windows: [stale], displays: [laptop], mirroring: false)
        XCTAssertEqual(ScreenWatch.evaluate(snapshot), .clear)
    }

    func testAnOrdinaryWindowInTheCornerIsIgnored() {
        var ordinary = indicator(on: laptop)
        ordinary.level = 0
        let snapshot = ScreenWatchSnapshot(windows: [ordinary], displays: [laptop], mirroring: false)
        XCTAssertEqual(ScreenWatch.evaluate(snapshot), .clear,
                       "only the level macOS parks the indicator at is read")
    }

    func testMirroringAloneIsEnough() {
        let snapshot = ScreenWatchSnapshot(windows: [cursor], displays: [laptop], mirroring: true)
        XCTAssertEqual(ScreenWatch.evaluate(snapshot), .mirrored)
    }

    func testTheIndicatorIsTheMoreSpecificThingToSay() {
        let snapshot = ScreenWatchSnapshot(
            windows: [indicator(on: laptop)], displays: [laptop], mirroring: true
        )
        XCTAssertEqual(ScreenWatch.evaluate(snapshot), .indicator)
    }

    func testEveryWatchedStateCanSayWhy() {
        XCTAssertNil(ScreenWatch.clear.reason)
        XCTAssertNotNil(ScreenWatch.indicator.reason)
        XCTAssertNotNil(ScreenWatch.mirrored.reason)
    }
}
