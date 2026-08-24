import XCTest
@testable import Trill

/// The rules for reading someone else's desktop. Every case here is a real
/// arrangement measured on this machine or one step away from it — the
/// numbers are points, in bottom-left global coordinates.
final class DesktopLayoutTests: XCTestCase {
    /// A display whose menu bar is auto-hidden: macOS reserves nothing, so
    /// `visibleFrame` runs to the very top and an overlay bar is invisible to
    /// AppKit. This is the arrangement that put banners on top of sketchybar.
    private let bare = CGRect(x: 0, y: 0, width: 1512, height: 982)

    private func window(_ rect: CGRect) -> DesktopLayout.Window {
        DesktopLayout.Window(frame: rect, isOverlay: false)
    }

    private func bar(_ rect: CGRect) -> DesktopLayout.Window {
        DesktopLayout.Window(frame: rect, isOverlay: true)
    }

    func testATopBarIsSubtractedEvenThoughAppKitCannotSeeIt() {
        // 36pt bar hugging the top of an unreserved screen.
        let usable = DesktopLayout.usableFrame(
            visible: bare,
            windows: [bar(CGRect(x: 0, y: 946, width: 1512, height: 36))]
        )
        XCTAssertEqual(usable.maxY, 946, "the stack starts below the bar, not over it")
        XCTAssertEqual(usable.minY, bare.minY)
    }

    func testABarAtTheBottomIsSubtractedToo() {
        let usable = DesktopLayout.usableFrame(
            visible: bare,
            windows: [bar(CGRect(x: 0, y: 0, width: 1512, height: 36))]
        )
        XCTAssertEqual(usable.minY, 36)
        XCTAssertEqual(usable.maxY, bare.maxY)
    }

    func testANarrowOverlayIsAHUDAndNotABar() {
        let usable = DesktopLayout.usableFrame(
            visible: bare,
            windows: [bar(CGRect(x: 400, y: 946, width: 400, height: 36))]
        )
        XCTAssertEqual(usable, bare, "a floating HUD does not shorten the screen")
    }

    func testAWallpaperSizedOverlayLeavesTheScreenAlone() {
        // The desktop picture and the Dock's backdrop arrive with the bar,
        // because the probe cannot filter desktop elements without also
        // filtering the bar (see `DesktopLayoutProbe`).
        let anchor = DesktopLayout.anchor(
            visible: bare,
            windows: [
                bar(bare),
                bar(CGRect(x: 0, y: 946, width: 1512, height: 36)),
                window(CGRect(x: 10, y: 33, width: 1492, height: 903)),
            ],
            inset: 12
        )
        XCTAssertEqual(anchor.maxY, 936, "the bar shortened the screen; the wallpaper did not")
        XCTAssertEqual(anchor.maxX, 1502)
    }

    func testACurtainIsNotMistakenForABar() {
        // A full-height overlay — a wallpaper app, a screen tint — spans the
        // width and touches the top, and subtracting it would leave nothing.
        let usable = DesktopLayout.usableFrame(
            visible: bare,
            windows: [bar(bare)]
        )
        XCTAssertEqual(usable, bare)
    }

    func testTheAnchorIsTheRightmostWindowsOwnCorner() {
        // Three tiled panes, 10pt gaps, under a 36pt bar: the real layout
        // this machine runs.
        let panes = [
            window(CGRect(x: 10, y: 33, width: 492, height: 903)),
            window(CGRect(x: 512, y: 33, width: 487, height: 903)),
            window(CGRect(x: 1009, y: 33, width: 492, height: 903)),
        ]
        let anchor = DesktopLayout.anchor(
            visible: bare,
            windows: panes + [bar(CGRect(x: 0, y: 946, width: 1512, height: 36))],
            inset: 12
        )
        XCTAssertEqual(anchor.maxX, 1501, "flush with the rightmost pane's right edge")
        XCTAssertEqual(anchor.maxY, 936, "flush with its top edge — the bar's gap, not ours")
        XCTAssertEqual(anchor.minY, 33, "and its bottom, so the stack sits in the same band")
    }

    func testAFullscreenWindowIsNotAnAnchor() {
        // It covers the bar, so its corner is not a gap anybody chose. Fall
        // back to the inset — and stay off the bar while doing it.
        let anchor = DesktopLayout.anchor(
            visible: bare,
            windows: [
                window(bare),
                bar(CGRect(x: 0, y: 946, width: 1512, height: 36)),
            ],
            inset: 12
        )
        XCTAssertEqual(anchor.maxY, 934)
        XCTAssertEqual(anchor.maxX, 1500)
    }

    func testSmallWindowsAreNotAnchors() {
        let anchor = DesktopLayout.anchor(
            visible: bare,
            windows: [window(CGRect(x: 1200, y: 900, width: 180, height: 60))],
            inset: 12
        )
        XCTAssertEqual(anchor.maxX, bare.maxX - 12, "a palette is not a pane to line up with")
    }

    func testAWindowLowOnTheScreenIsNotAnAnchor() {
        let anchor = DesktopLayout.anchor(
            visible: bare,
            windows: [window(CGRect(x: 1000, y: 20, width: 480, height: 300))],
            inset: 12
        )
        XCTAssertEqual(anchor.maxY, bare.maxY - 12, "banners don't drop to meet a window at the bottom")
    }

    func testAnEmptyDesktopFallsBackToTheInset() {
        let anchor = DesktopLayout.anchor(visible: bare, windows: [], inset: 12)
        XCTAssertEqual(anchor, bare.insetBy(dx: 12, dy: 12))
    }

    func testTheStackHangsFromTheMeasuredAnchor() throws {
        let screen = ScreenDescriptor(
            id: "laptop",
            frame: bare,
            visibleFrame: bare,
            contentFrame: CGRect(x: 10, y: 83, width: 1491, height: 853)
        )
        let first = try XCTUnwrap(BannerGeometry.slotFrame(on: screen, index: 0))
        XCTAssertEqual(first.maxX, 1501, "the card's right edge is the window's right edge")
        XCTAssertEqual(first.maxY, 936, "and its top edge is the window's top edge")
        XCTAssertLessThan(
            BannerGeometry.capacity(on: screen),
            BannerGeometry.capacity(
                on: ScreenDescriptor(id: "laptop", frame: bare, visibleFrame: bare)
            ),
            "a shortened band holds fewer cards — the queue keeps the rest"
        )
    }
}
