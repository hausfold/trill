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

    /// The anchor the platform would hand the compositor on a first reading:
    /// the pane's own padding when one is tiled at the corner, 12pt all round
    /// when not (`DesktopLayoutProbe.padding` remembers between readings;
    /// this is one reading).
    private func anchor(windows: [DesktopLayout.Window]) -> CGRect {
        DesktopLayout.anchor(
            visible: bare,
            windows: windows,
            padding: DesktopLayout.measuredPadding(visible: bare, windows: windows) ?? .uniform(12)
        )
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
        let anchor = anchor(windows: [
                bar(bare),
                bar(CGRect(x: 0, y: 946, width: 1512, height: 36)),
                window(CGRect(x: 10, y: 33, width: 1492, height: 903)),
            ])
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
        let anchor = anchor(windows: panes + [bar(CGRect(x: 0, y: 946, width: 1512, height: 36))])
        XCTAssertEqual(anchor.maxX, 1501, "flush with the rightmost pane's right edge")
        XCTAssertEqual(anchor.maxY, 936, "flush with its top edge — the bar's gap, not ours")
        XCTAssertEqual(anchor.minY, 33, "and its bottom, so the stack sits in the same band")
    }

    func testAFullscreenWindowIsNotAnAnchor() {
        // It covers the bar, so its corner is not a gap anybody chose. Fall
        // back to the inset — and stay off the bar while doing it.
        let anchor = anchor(windows: [
                window(bare),
                bar(CGRect(x: 0, y: 946, width: 1512, height: 36)),
            ])
        XCTAssertEqual(anchor.maxY, 934)
        XCTAssertEqual(anchor.maxX, 1500)
    }

    func testSmallWindowsAreNotAnchors() {
        let anchor = anchor(windows: [window(CGRect(x: 1200, y: 900, width: 180, height: 60))])
        XCTAssertEqual(anchor.maxX, bare.maxX - 12, "a palette is not a pane to line up with")
    }

    func testAWindowLowOnTheScreenIsNotAnAnchor() {
        let anchor = anchor(windows: [window(CGRect(x: 1000, y: 20, width: 480, height: 300))])
        XCTAssertEqual(anchor.maxY, bare.maxY - 12, "banners don't drop to meet a window at the bottom")
    }

    func testAnEmptyDesktopFallsBackToTheInset() {
        XCTAssertNil(DesktopLayout.measuredPadding(visible: bare, windows: []))
        let anchor = anchor(windows: [])
        XCTAssertEqual(anchor.maxX, bare.maxX - 12)
        XCTAssertEqual(anchor.maxY, bare.maxY - 12)
        XCTAssertEqual(anchor.minY, bare.minY + 12)
        XCTAssertEqual(anchor.minX, bare.minX, "cards hang from the right; the left edge is never measured")
    }

    func testAFloatingWindowIsNotAStop() {
        // One Ghostty window floating in the middle of the workspace, under
        // the same bar. The stack used to hang from its corner — a card
        // 280pt in from the screen edge, over the middle of the terminal.
        let floating = window(CGRect(x: 265, y: 195, width: 964, height: 556))
        let windows = [floating, bar(CGRect(x: 0, y: 946, width: 1512, height: 36))]
        XCTAssertNil(
            DesktopLayout.measuredPadding(visible: bare, windows: windows),
            "a window that far from the corner is not tiled there"
        )
        let anchor = anchor(windows: windows)
        XCTAssertEqual(anchor.maxX, 1500, "the stop is the corner, 12pt in — not the window")
        XCTAssertEqual(anchor.maxY, 934, "and still under the bar")
    }

    func testTheStopIsTheTiledCornerEvenWithNothingTiled() throws {
        // The stop is a property of the WM, not of the workspace in front:
        // the padding the last tiled pane showed carries over to a floating
        // workspace, so switching between them never moves the corner.
        let topBar = bar(CGRect(x: 0, y: 946, width: 1512, height: 36))
        let panes = [
            window(CGRect(x: 10, y: 33, width: 492, height: 903)),
            window(CGRect(x: 1009, y: 33, width: 492, height: 903)),
            topBar,
        ]
        let measured = try XCTUnwrap(DesktopLayout.measuredPadding(visible: bare, windows: panes))
        XCTAssertEqual(measured, DesktopLayout.Padding(top: 10, right: 11, bottom: 33))

        let floating = [window(CGRect(x: 265, y: 195, width: 964, height: 556)), topBar]
        let anchor = DesktopLayout.anchor(visible: bare, windows: floating, padding: measured)
        XCTAssertEqual(anchor.maxX, 1501, "same right edge the tiled pane had")
        XCTAssertEqual(anchor.maxY, 936, "same top edge")
        XCTAssertEqual(anchor.minY, 33, "same band")
    }

    func testThePaneNearestTheCornerWins() {
        // A floating window dragged up over the top-right pane, close enough
        // to the corner to be in reach: the pane is nearer, the pane wins.
        let pane = window(CGRect(x: 1009, y: 33, width: 492, height: 903))
        let over = window(CGRect(x: 1150, y: 660, width: 300, height: 300))
        let measured = DesktopLayout.measuredPadding(visible: bare, windows: [over, pane])
        XCTAssertEqual(measured?.right, 11)
        XCTAssertEqual(measured?.top, 46)
    }

    func testAWindowPastTheScreenEdgeIsNotAStop() {
        // Dragged half off the right edge: its corner is off screen, and a
        // corner nobody can see is not one to line up with.
        let dragged = window(CGRect(x: 1200, y: 450, width: 600, height: 530))
        XCTAssertNil(DesktopLayout.measuredPadding(visible: bare, windows: [dragged]))
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
