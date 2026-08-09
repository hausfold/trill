import XCTest
@testable import Trill

final class ScreenGeometryTests: XCTestCase {
    // A 16:10 laptop with a menu bar carved off the top.
    private let laptop = ScreenDescriptor(
        id: "laptop",
        frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 944)
    )

    // A second display positioned to the right in global coordinates.
    private let external = ScreenDescriptor(
        id: "external",
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415)
    )

    func testSlotsDealDownwardFromTopRightAsAStack() throws {
        let first = try XCTUnwrap(BannerGeometry.slotFrame(on: laptop, index: 0))
        let second = try XCTUnwrap(BannerGeometry.slotFrame(on: laptop, index: 1))

        XCTAssertEqual(first.maxX, laptop.visibleFrame.maxX - BannerGeometry.inset)
        XCTAssertEqual(first.maxY, laptop.visibleFrame.maxY - BannerGeometry.inset)
        XCTAssertEqual(
            second.maxY - first.minY, BannerGeometry.overlap,
            "each card laps over its elder's bottom edge — a deck, not a spaced list"
        )
        XCTAssertEqual(
            first.minX - second.minX, BannerGeometry.step,
            "cards step left by `step` — which is 0, so the stack is flush"
        )
        XCTAssertEqual(
            second.maxX, laptop.visibleFrame.maxX - BannerGeometry.inset,
            "a flush stack keeps every right edge on the same line"
        )
    }

    func testSlotsStayInsideVisibleFrame() {
        for index in 0..<BannerGeometry.capacity(on: laptop) {
            guard let frame = BannerGeometry.slotFrame(on: laptop, index: index) else {
                return XCTFail("capacity promised slot \(index)")
            }
            XCTAssertTrue(
                laptop.visibleFrame.contains(frame),
                "slot \(index) escaped the visible frame"
            )
        }
    }

    func testIndexBeyondCapacityYieldsNoFrame() {
        let capacity = BannerGeometry.capacity(on: laptop)
        XCTAssertNil(BannerGeometry.slotFrame(on: laptop, index: capacity))
        XCTAssertNil(BannerGeometry.slotFrame(on: laptop, index: -1))
    }

    func testSecondaryDisplayUsesItsOwnGlobalOrigin() throws {
        let frame = try XCTUnwrap(BannerGeometry.slotFrame(on: external, index: 0))
        XCTAssertTrue(external.visibleFrame.contains(frame))
        XCTAssertGreaterThan(frame.minX, external.frame.minX)
    }

    func testTinyScreenReportsZeroCapacityInsteadOfOverflowing() {
        let tiny = ScreenDescriptor(
            id: "tiny",
            frame: CGRect(x: 0, y: 0, width: 400, height: 60),
            visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 60)
        )
        XCTAssertEqual(BannerGeometry.capacity(on: tiny), 0)
        XCTAssertNil(BannerGeometry.slotFrame(on: tiny, index: 0))
    }

    // MARK: - Expanded folds

    func testCollapsedCardIsAlwaysTheBaseSize() {
        XCTAssertEqual(BannerGeometry.cardSize(foldedCount: 0, expanded: false, maxRows: 40), BannerGeometry.size)
        XCTAssertEqual(BannerGeometry.cardSize(foldedCount: 9, expanded: false, maxRows: 40), BannerGeometry.size)
        XCTAssertEqual(
            BannerGeometry.cardSize(foldedCount: 0, expanded: true, maxRows: 40), BannerGeometry.size,
            "hovering a banner with nothing folded behind it must not grow it"
        )
        XCTAssertEqual(
            BannerGeometry.cardSize(foldedCount: 9, expanded: true, maxRows: 0), BannerGeometry.size,
            "a screen with room for no rows leaves the card the height it arrived at"
        )
    }

    func testExpandedCardGrowsByExactlyItsFoldRows() {
        let two = BannerGeometry.cardSize(foldedCount: 2, expanded: true, maxRows: 40)
        XCTAssertEqual(two.width, BannerGeometry.size.width, "folds grow downward only")
        XCTAssertEqual(
            two.height,
            BannerGeometry.size.height + BannerGeometry.foldListInset + 2 * BannerGeometry.foldRowHeight
        )

        // A normal burst is listed in full — this is the whole point of
        // capping by height instead of by a constant: ten fit, so ten show.
        XCTAssertEqual(BannerGeometry.foldRowCount(folded: 9, maxRows: 40), 9)
        XCTAssertEqual(
            BannerGeometry.foldListedCount(folded: 9, maxRows: 40), 9,
            "nine folded on a screen with room for forty rows: no 'and N earlier'"
        )
    }

    func testAHugeBurstStopsAtTheRowsTheScreenPaidForAndAdmitsTheRest() {
        // The tail collapses into one "and N earlier" row, so a burst of 200
        // and a burst of 20,000 are the same height — never taller than the
        // rows the screen allowed.
        let rows = BannerGeometry.foldRowCount(folded: 200, maxRows: 12)
        XCTAssertEqual(rows, 12)
        XCTAssertEqual(BannerGeometry.foldRowCount(folded: 20_000, maxRows: 12), rows)
        XCTAssertEqual(
            BannerGeometry.foldListedCount(folded: 200, maxRows: 12), 11,
            "one of the twelve rows is spent saying how much is not shown"
        )
    }

    func testEveryFoldRowIsEitherANamedEventOrTheEarlierLine() {
        // The card's height is fixed from `foldRowCount`, so a row the view
        // draws without a row the height paid for is a silent clip.
        for maxRows in 0...12 {
            for folded in 0...30 {
                let listed = BannerGeometry.foldListedCount(folded: folded, maxRows: maxRows)
                let rows = BannerGeometry.foldRowCount(folded: folded, maxRows: maxRows)
                // No room and nothing folded both mean no list at all — not
                // a bare "and N earlier" on a card that never grew.
                let expected = (maxRows == 0 || folded == 0)
                    ? 0
                    : listed + (folded > listed ? 1 : 0)
                XCTAssertEqual(
                    rows, expected,
                    "\(folded) folded in \(maxRows) rows: \(listed) named plus at most one 'and N earlier'"
                )
                XCTAssertLessThanOrEqual(
                    rows, maxRows,
                    "\(folded) folded must never draw more than the \(maxRows) rows the card is tall for"
                )
                XCTAssertLessThanOrEqual(listed, folded, "no row may name an event that isn't there")
            }
        }
    }

    func testFoldRowCapacityFillsTheScreenAndShrinksDownTheStack() {
        let top = BannerGeometry.foldRowCapacity(on: laptop, index: 0)
        XCTAssertGreaterThan(
            top, 10,
            "a 944pt visible frame has room for a normal burst — 10 rows — many times over"
        )

        // A card further down the deck starts lower, so it has less room.
        let second = BannerGeometry.foldRowCapacity(on: laptop, index: 1)
        XCTAssertEqual(
            top - second,
            Int((BannerGeometry.size.height - BannerGeometry.overlap) / BannerGeometry.foldRowHeight),
            "each card down the stack loses the rows its predecessor's advance cost"
        )
        XCTAssertGreaterThan(
            BannerGeometry.foldRowCapacity(on: external, index: 0), top,
            "a taller display lists more of the same burst"
        )
    }

    func testAnExpandedCardNeverOutgrowsTheVisibleFrame() throws {
        // The contract the whole change exists for: however big the burst,
        // the card the screen sized fits on the screen.
        for screen in [laptop, external] {
            for index in 0..<BannerGeometry.capacity(on: screen) where index < 3 {
                let rows = BannerGeometry.foldRowCapacity(on: screen, index: index)
                let sizes = Array(repeating: BannerGeometry.size, count: index)
                    + [BannerGeometry.cardSize(foldedCount: 20_000, expanded: true, maxRows: rows)]
                let frames = BannerGeometry.stackFrames(on: screen, sizes: sizes)
                let card = try XCTUnwrap(
                    frames[index],
                    "a fold sized from row capacity must still get a slot (\(screen.id), index \(index))"
                )
                XCTAssertTrue(
                    screen.visibleFrame.contains(card),
                    "an expanded fold escaped the visible frame on \(screen.id) at index \(index)"
                )
            }
        }
    }

    func testAShortScreenRefusesFoldRowsRatherThanClippingThem() {
        let short = ScreenDescriptor(
            id: "short",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 120),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 120)
        )
        XCTAssertEqual(BannerGeometry.foldRowCapacity(on: short, index: 0), 0)
        XCTAssertEqual(
            BannerGeometry.cardSize(foldedCount: 50, expanded: true, maxRows: 0),
            BannerGeometry.size,
            "no room for a list means no list, not a card taller than the display"
        )
    }

    func testExpandedCardPushesTheCardsBelowItDown() throws {
        let collapsed = BannerGeometry.cardSize(foldedCount: 3, expanded: false, maxRows: 40)
        let expanded = BannerGeometry.cardSize(foldedCount: 3, expanded: true, maxRows: 40)

        let flat = BannerGeometry.stackFrames(on: laptop, sizes: [collapsed, BannerGeometry.size])
        let grown = BannerGeometry.stackFrames(on: laptop, sizes: [expanded, BannerGeometry.size])

        let before = try XCTUnwrap(flat[1])
        let after = try XCTUnwrap(grown[1])
        XCTAssertEqual(before.maxY - after.maxY, expanded.height - collapsed.height)
        XCTAssertEqual(before.minX, after.minX, "growing a fold must not shift the stack sideways")
        XCTAssertEqual(try XCTUnwrap(grown[0]).size, expanded)
    }

    func testStackDropsEveryCardOnceItRunsOffTheScreen() {
        let shallow = ScreenDescriptor(
            id: "shallow",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 200),
            visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 200)
        )
        let sizes = Array(repeating: BannerGeometry.size, count: 4)
        let frames = BannerGeometry.stackFrames(on: shallow, sizes: sizes)

        XCTAssertNotNil(frames[0])
        guard let firstMiss = frames.firstIndex(where: { $0 == nil }) else {
            return XCTFail("a 200pt screen cannot hold four banners")
        }
        XCTAssertTrue(
            frames[firstMiss...].allSatisfy { $0 == nil },
            "once the stack escapes it never comes back further down"
        )
    }
}
