import Foundation

/// Which display a banner is drawn on — a *rule's* answer, never a screen id.
///
/// The user's rules say "chats on the laptop"; what "the laptop" is depends on
/// what is plugged in right now, and only the compositor can answer that. So
/// the policy engine decides an intent, the compositor resolves it
/// (`DisplayRouter`), and the queue counts cards against whatever came back.
///
/// Every target falls back to `primary` rather than to nothing: a rule that
/// names a display you unplugged must not silently swallow its events.
enum DisplayTarget: String, Codable, Sendable, CaseIterable {
    /// The display carrying the menu bar, where macOS draws its own banners.
    /// The default, and what every event did before routing existed.
    case primary
    /// The display the pointer is on — "the one you're facing". Read at
    /// arrival and then fixed: a card that changed screens because you
    /// reached for the other keyboard would be a card you lose.
    case active
    /// This Mac's own panel. A desktop Mac has none, and falls back.
    case builtin
    /// The first attached display that isn't the built-in one. A laptop with
    /// nothing plugged in has none, and falls back.
    case external
}

/// Where each target currently points, and what fits there — one topology,
/// reduced to the two things the queue counts with. Pure: the compositor
/// measures the real screens and hands this over, so lane arithmetic is
/// testable without a display.
struct DisplayRouting: Equatable, Sendable {
    /// Screen id per target. A target absent here has no display at all
    /// (which, given `primary` is the universal fallback, means no screens
    /// are attached) and its events wait rather than draw.
    var screens: [DisplayTarget: String] = [:]
    /// How many collapsed cards each named screen fits.
    var capacity: [String: Int] = [:]

    /// No displays: everything waits, nothing is lost.
    static let none = DisplayRouting()

    /// Every target on one screen with one capacity — a single-display Mac,
    /// and what a queue built without a compositor gets.
    static func single(_ id: String = "primary", capacity: Int) -> DisplayRouting {
        DisplayRouting(
            screens: Dictionary(uniqueKeysWithValues: DisplayTarget.allCases.map { ($0, id) }),
            capacity: [id: capacity]
        )
    }

    func screen(for target: DisplayTarget) -> String? { screens[target] }

    /// Cards that fit on a screen. An unknown (unplugged, never-seen) screen
    /// fits nothing — its cards queue until it comes back.
    func capacity(of screen: String?) -> Int {
        screen.flatMap { capacity[$0] } ?? 0
    }
}
