import AppKit
import SwiftUI

/// Trill's proportional type — the one place a family name becomes a `Font`.
///
/// Every string trill draws for a person to read goes through here rather than
/// through SwiftUI's `.system(…)`, so that one line in
/// `~/.config/trill/config.json` sets the family for the whole app: banners,
/// the ledge, the inbox and Settings alike. Absent that line — the default —
/// every call here resolves to `.system(…)` and trill renders exactly as it
/// always has, which is why the key's empty value is not a family name but a
/// deliberate "whatever macOS is using".
///
/// Three things it deliberately does not cover.
///
/// **A symbol is not text.** `Image(systemName:)` is sized with
/// `.font(.system(size:))` all over this app, and an SF Symbol handed a text
/// face is scaled by that face's metrics instead of Apple's — a chevron that
/// grows when you change your reading font. Those call sites keep `.system`;
/// this type is for `Text`. A `Label`'s icon is the exception that proves it:
/// it takes the family with its text, because an icon that no longer matches
/// the size of the words beside it reads as broken.
///
/// **Monospaced type stays monospaced.** A source slug and a timestamp carry
/// `.monospaced()` because a column that shifts under a proportional face is
/// harder to read, not easier. The mono family is a separate decision and
/// reaches this Mac through the terminal, not through here.
///
/// **A family that isn't installed falls back silently**, because that is what
/// CoreText does with a name it can't resolve and there is nothing better for
/// a render pass to do about it. Saying so belongs where somebody can act on
/// it, which is Settings ▸ General — the switch is a *request*, the line under
/// it is a *reading*.
enum AppFont {
    // MARK: - The family

    /// What the file asks for, or `nil` for the system font.
    ///
    /// The read is unbuffered on purpose: `ConfigFileStore` already follows
    /// the file, so a family typed into it is on the next card without a
    /// restart, and a cache here would only be a second copy to invalidate.
    static var family: String? { resolve(ConfigFileStore.shared.current().fontFamily) }

    /// Pure, so what counts as "the system font" is a test rather than a
    /// render: empty, blank, and the names macOS's own UI family answers to.
    ///
    /// That last case is the one that matters. A desktop generating this key
    /// writes the family it was told to use, and the usual default is macOS's
    /// own — `Font.custom(".AppleSystemUIFont", …)` *works*, and freezes the
    /// weight and optical size SwiftUI picks per text style, so "I left it at
    /// the default" would render subtly unlike leaving the key out. Name the
    /// system font and you get the system font.
    static func resolve(_ configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !systemNames.contains(trimmed.lowercased()) else { return nil }
        return trimmed
    }

    private static let systemNames: Set<String> = [
        ".applesystemuifont",
        "applesystemuifont",
        ".sf ns",
        "system",
        "system font",
        "-apple-system",
    ]

    /// Whether this Mac can actually draw the named family. Not consulted when
    /// rendering — CoreText's own fallback is both faster and the same answer —
    /// but Settings needs it to tell a family that is working from one that is
    /// merely spelled correctly.
    static func isInstalled(_ family: String) -> Bool {
        let manager = NSFontManager.shared
        if manager.availableFontFamilies.contains(where: {
            $0.caseInsensitiveCompare(family) == .orderedSame
        }) { return true }
        // PostScript names resolve through `Font.custom` too, and are what a
        // font-info panel puts in front of somebody about to copy one.
        return NSFont(name: family, size: NSFont.systemFontSize) != nil
    }

    // MARK: - Text styles

    /// One of SwiftUI's semantic styles, in trill's family.
    ///
    /// The point size is macOS's own for that style rather than a table
    /// written down here — a table would be right until Apple moved one — and
    /// `relativeTo:` keeps the custom face scaling with the system's text size
    /// the way `.system(_:)` does.
    static func style(_ textStyle: Font.TextStyle) -> Font {
        style(textStyle, family: family)
    }

    /// The same decision with the family handed in, so a test can prove the
    /// one claim that matters most here: with nobody's family named, every
    /// call is *the same `Font`* trill drew before this key existed.
    static func style(_ textStyle: Font.TextStyle, family: String?) -> Font {
        guard let family else { return .system(textStyle) }
        return .custom(family, size: pointSize(of: textStyle), relativeTo: textStyle)
            .weight(weight(of: textStyle))
    }

    /// A fixed point size, the analogue of `.system(size:weight:)`. Used where
    /// a card's proportions are drawn to a number rather than to a style.
    ///
    /// The weight is optional rather than defaulted to `.regular` because
    /// SwiftUI's own is: `.system(size: 11)` and `.system(size: 11, weight:
    /// .regular)` are two different `Font`s, and only one of them is what the
    /// call site being replaced here asked for.
    static func size(_ points: CGFloat, weight: Font.Weight? = nil) -> Font {
        size(points, weight: weight, family: family)
    }

    static func size(_ points: CGFloat, weight: Font.Weight? = nil, family: String?) -> Font {
        guard let family else { return .system(size: points, weight: weight) }
        let sized = Font.custom(family, fixedSize: points)
        return weight.map(sized.weight) ?? sized
    }

    static var caption2: Font { style(.caption2) }
    static var caption: Font { style(.caption) }
    static var footnote: Font { style(.footnote) }
    static var subheadline: Font { style(.subheadline) }
    static var callout: Font { style(.callout) }
    static var body: Font { style(.body) }
    static var headline: Font { style(.headline) }
    static var title3: Font { style(.title3) }
    static var title2: Font { style(.title2) }

    /// The weight macOS gives a style in the system face, which a custom face
    /// has to be *asked* for — every family ships a regular, and only
    /// `.headline` is anything else.
    static func weight(of textStyle: Font.TextStyle) -> Font.Weight {
        textStyle == .headline ? .semibold : .regular
    }

    static func pointSize(of textStyle: Font.TextStyle) -> CGFloat {
        NSFont.preferredFont(forTextStyle: appKitStyle(of: textStyle)).pointSize
    }

    /// SwiftUI and AppKit spell the same eleven styles differently and offer
    /// no bridge between them.
    private static func appKitStyle(of textStyle: Font.TextStyle) -> NSFont.TextStyle {
        switch textStyle {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .subheadline: return .subheadline
        case .callout: return .callout
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
}

extension View {
    /// Set trill's family as the default for everything underneath, so a label
    /// nobody gave an explicit `.font` to is in it too — the sidebar rows, a
    /// toggle's title, a button.
    ///
    /// A no-op while no family is named: `EnvironmentValues.font` is optional,
    /// and pushing `.body` into it would flatten the per-control defaults
    /// SwiftUI picks for a settings window that nobody asked to restyle.
    ///
    /// When somebody *has* named one, that flattening is the deal rather than
    /// an oversight: a `Toggle`'s label or a `.controlSize(.small)` button's
    /// title is unreachable any other way, and it renders at body size as the
    /// price. Naming a family means everything is in it.
    func trillType() -> some View {
        environment(\.font, AppFont.family == nil ? nil : AppFont.body)
    }
}
