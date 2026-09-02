import AppKit
import SwiftUI

// The settings-window chrome, shared by shape with perch and pounce: a
// sidebar of panes, and each pane a scrolling column of cards. Deliberately a
// copy rather than a shared package — it is a couple of hundred lines of plain
// SwiftUI, and trill builds through Xcode while pounce builds through a bare
// `swiftc` invocation in Nix, so a dependency would cost more than the
// duplication does. Keep the three in step by eye; if that stops working,
// that is when it earns a package.

// MARK: - Pane scaffold

/// One settings pane: a title, a line saying what the pane is for, and a
/// scrolling column of cards.
///
/// The scroll view is the whole reason the window can be small. Everything
/// inside is laid out at its natural height and the pane scrolls when it
/// doesn't fit, so the window opens at a size that fits a laptop screen instead
/// of stretching to hold the longest pane.
struct SettingsPaneLayout<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(AppFont.size(19, weight: .semibold))
                    Text(subtitle)
                        .font(AppFont.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            // Capped and centred: a settings window dragged out to 1400pt
            // should not carry 1300pt lines of explanation.
            .frame(maxWidth: 700, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 26)
            .frame(maxWidth: .infinity)
        }
        // No rubber-band on a pane that already fits — a settings window that
        // bounces when there is nothing to scroll reads as broken.
        .scrollBounceBehavior(.basedOnSize)
    }
}

// MARK: - Cards

/// A group of rows on one plate: the box every mac settings pane is built out
/// of, sized to its content and painted for the current appearance.
///
/// Rows separate themselves with `SettingsDivider()` rather than the card
/// inserting separators for them. Walking a `ViewBuilder`'s children needs
/// `Group(subviews:)` (macOS 15) or the underscored variadic-view API, and
/// neither is worth taking on for a hairline.
struct SettingsCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsPalette.cardFill(scheme), in: shape)
        .overlay(shape.strokeBorder(SettingsPalette.cardBorder(scheme), lineWidth: 1))
        // Light appearance puts a white card on a grey window, and the hairline
        // alone doesn't lift it. Dark already has the contrast; a shadow there
        // only muddies the edge.
        .shadow(color: .black.opacity(scheme == .dark ? 0 : 0.05), radius: 1.5, y: 0.5)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }
}

/// A hairline between two rows of a card, inset to the row's text column.
struct SettingsDivider: View {
    var inset: CGFloat = 14

    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// One setting: symbol, label, the line under it that says what turning it on
/// actually does, and the control that does it.
struct SettingsRow<Control: View>: View {
    var symbol: String?
    var tint: Color = .secondary
    var title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(tint)
                    .frame(width: 18, alignment: .center)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFont.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

/// A row whose whole width is one sentence — an empty list, or a paired-device
/// list before anything is paired.
struct SettingsPlaceholderRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(AppFont.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
    }
}

/// The explanation under a card. Long copy lives here, not in a row subtitle.
struct SettingsFootnote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(AppFont.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
            .padding(.top, -8)
    }
}

/// A tinted aside — where the settings file lives, or what a failed write
/// said. Not a card: it carries no controls.
struct SettingsNote: View {
    var symbol: String
    var tint: Color = .secondary
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 16)
            Text(text)
                .font(AppFont.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }
}

/// The rounded, tinted glyph that names a pane in the sidebar — the one shape
/// that says "settings window" on this platform at a glance.
struct SettingsPaneChip: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(tint.gradient)
            .frame(width: 18, height: 18)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

// MARK: - Palette

/// The two colors the pane chrome mixes, resolved per appearance.
///
/// Not `controlBackgroundColor`: in dark mode that is *darker* than the window
/// it sits on, so cards would sink into the pane instead of lifting off it. A
/// white wash over the window fill lifts in dark and reads as plain white in
/// light, which is what a mac settings box looks like in both.
enum SettingsPalette {
    static func cardFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.055) : Color.white
    }

    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.07)
    }
}
