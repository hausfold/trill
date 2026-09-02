import SwiftUI
import XCTest
@testable import Trill

/// The proportional family is one string in `config.json`, and everything
/// interesting about it happens before a `Font` exists: what counts as "no
/// family", and which names mean the system's own. Those are the answers a
/// render pass can't be asked for, so they are pure and they are tested here.
final class AppFontTests: XCTestCase {
    func testAnUnnamedFamilyIsTheSystemFont() {
        XCTAssertNil(AppFont.resolve(""))
        XCTAssertNil(AppFont.resolve("   "))
        XCTAssertNil(AppFont.resolve("\n\t"))
    }

    /// The case a desktop generating this key actually hits: it writes the
    /// family it was configured with, and the usual default *is* macOS's own.
    /// `Font.custom(".AppleSystemUIFont", …)` would draw — and would freeze
    /// the optical size and weight SwiftUI picks per text style, so "left at
    /// the default" would render subtly unlike leaving the key out.
    func testTheSystemFontsOwnNamesResolveToTheSystemFont() {
        XCTAssertNil(AppFont.resolve(".AppleSystemUIFont"))
        XCTAssertNil(AppFont.resolve(".applesystemuifont"))
        XCTAssertNil(AppFont.resolve("System"))
        XCTAssertNil(AppFont.resolve("system font"))
        XCTAssertNil(AppFont.resolve("-apple-system"))
    }

    func testANamedFamilyIsPassedThroughVerbatim() {
        XCTAssertEqual(AppFont.resolve("Atkinson Hyperlegible"), "Atkinson Hyperlegible")
        // Case is the font's own business — CoreText matches case-insensitively
        // and a family called "iA Writer Quattro" must not be tidied.
        XCTAssertEqual(AppFont.resolve("iA Writer Quattro S"), "iA Writer Quattro S")
    }

    /// A hand-edited file is where a stray space comes from, and " Inter" is
    /// not a family anyone has.
    func testSurroundingWhitespaceIsTrimmedRatherThanSearchedFor() {
        XCTAssertEqual(AppFont.resolve("  Inter \n"), "Inter")
    }

    /// Every family ships a regular; only `.headline` is anything else in the
    /// system face, and a custom face has to be *asked* for that weight or the
    /// inbox's titles come out lighter than they were.
    func testOnlyHeadlineCarriesAWeightOfItsOwn() {
        XCTAssertEqual(AppFont.weight(of: .headline), .semibold)
        for style: Font.TextStyle in [.caption2, .caption, .footnote, .subheadline, .callout, .body, .title3, .title2] {
            XCTAssertEqual(AppFont.weight(of: style), .regular, "\(style) should ride the family's regular")
        }
    }

    /// The claim the whole change rests on: an unconfigured trill draws in
    /// exactly the `Font`s it drew before this key existed, not in a
    /// look-alike. `Font` is `Equatable`, so this is checkable rather than a
    /// thing to squint at.
    func testWithNoFamilyEveryCallIsTheFontTrillAlreadyDrew() {
        for style: Font.TextStyle in [.caption2, .caption, .footnote, .subheadline, .callout, .body, .headline, .title3, .title2] {
            XCTAssertEqual(AppFont.style(style, family: nil), .system(style))
        }
        XCTAssertEqual(AppFont.size(19, weight: .semibold, family: nil), .system(size: 19, weight: .semibold))
        XCTAssertEqual(AppFont.size(11, family: nil), .system(size: 11))
    }

    /// And with one named, the style keeps macOS's own point size for that
    /// style rather than a number written down in trill — a hard-coded table
    /// would be right until Apple moved one.
    func testANamedFamilyKeepsTheStylesOwnSizeAndWeight() {
        XCTAssertEqual(
            AppFont.style(.headline, family: "Helvetica"),
            .custom("Helvetica", size: AppFont.pointSize(of: .headline), relativeTo: .headline).weight(.semibold)
        )
        XCTAssertEqual(
            AppFont.style(.caption, family: "Helvetica"),
            .custom("Helvetica", size: AppFont.pointSize(of: .caption), relativeTo: .caption).weight(.regular)
        )
        // A call site drawn to a number stays at that number.
        XCTAssertEqual(AppFont.size(19, weight: .semibold, family: "Helvetica"),
                       .custom("Helvetica", fixedSize: 19).weight(.semibold))
        XCTAssertNotEqual(AppFont.style(.body, family: "Helvetica"), .system(.body))
    }

    /// macOS always has its own UI font, and never has this one.
    func testInstalledSaysWhatThisMacCanActuallyDraw() {
        XCTAssertTrue(AppFont.isInstalled("Helvetica"))
        XCTAssertFalse(AppFont.isInstalled("No Such Family 4c1f9a"))
    }
}
