import AppKit
import CoreGraphics
import os.log

// MARK: - The verdict

/// Whether anything other than the person sitting in front of this Mac can
/// see the screen right now — and what said so.
///
/// **macOS has no API for "is my display being captured".** `NSScreen` has no
/// `isCaptured` (that is UIKit's), `CGDisplayIsCaptured` has been unavailable
/// since 10.9, the session dictionary carries no such key, and nothing is
/// posted on the Darwin or distributed notification centres when a capture
/// starts — all four checked against this SDK and this Mac on 2026-08-25,
/// macOS 26.5. What macOS *does* do is put its own in-use indicator on the
/// screen, and that window is visible in the window list without any
/// permission. So that is what trill reads, and this type says exactly what
/// that means rather than pretending to more.
enum ScreenWatch: Equatable, Sendable {
    /// Nothing trill can see is watching.
    case clear
    /// macOS is drawing its in-use indicator. That one dot covers screen
    /// capture, the camera and the microphone — measured identical for a
    /// `screencapture -V` recording and for a live mic — so trill treats all
    /// three as "you are in front of an audience".
    case indicator
    /// A display is mirrored onto another one: AirPlay, a projector, the
    /// meeting-room TV. Certain, unlike the indicator, and just as public.
    case mirrored

    var isWatched: Bool { self != .clear }

    /// What Settings says out loud — including what the signal cannot tell
    /// apart, because a user whose banners went quiet deserves the real
    /// reason and not a guess dressed as one.
    var reason: String? {
        switch self {
        case .clear:
            return nil
        case .indicator:
            return "macOS is showing its in-use indicator — the screen is being captured, or the camera or mic is live."
        case .mirrored:
            return "A display is mirrored, so whatever is on this screen is on another one too."
        }
    }
}

// MARK: - The reading, as a value

/// One reading of the window server and the display list, reduced to the
/// three things the decision actually uses. Pure input: the classifier below
/// is testable without a display, a capture, or a Mac at all.
struct ScreenWatchSnapshot: Equatable, Sendable {
    /// A window from `CGWindowListCopyWindowInfo`, minus everything the
    /// decision doesn't read — and minus, deliberately, the window's *name*:
    /// `kCGWindowName` needs Screen Recording permission, and an app that
    /// asked for the screen in order to be shy about the screen would be a
    /// joke. Owner, level and bounds come back without any grant.
    struct Window: Equatable, Sendable {
        var level: Int
        var frame: CGRect
        var onScreen: Bool
    }

    var windows: [Window] = []
    /// Display bounds in global, top-left-origin coordinates — the same space
    /// `kCGWindowBounds` is in, which is the only reason the corner test
    /// below can compare the two.
    var displays: [CGRect] = []
    /// Any online display mirrored onto another (hardware mirrors excluded —
    /// those are a property of the machine, not of who is watching).
    var mirroring = false
}

extension ScreenWatch {
    /// The level macOS parks the in-use indicator at — the same one the
    /// cursor rides, above every ordinary window.
    static let indicatorLevel = Int(CGWindowLevelForKey(.cursorWindow))

    /// Measured 2026-08-25 on macOS 26.5: the indicator is a 28×28 window
    /// whose top-right corner sits 3pt from the display's, at the right end
    /// of the menu bar. The slack is for other menu-bar geometries (a taller
    /// bar, a notch, a scaled display) — not for a different window.
    static let indicatorSide: ClosedRange<CGFloat> = 20...48
    static let indicatorCornerSlack: CGFloat = 40

    /// The whole decision, as a pure function of one reading.
    ///
    /// The indicator wins over mirroring only because it is the more specific
    /// thing to say; both mean the same to a card.
    static func evaluate(_ snapshot: ScreenWatchSnapshot) -> ScreenWatch {
        if snapshot.windows.contains(where: { isIndicator($0, on: snapshot.displays) }) {
            return .indicator
        }
        return snapshot.mirroring ? .mirrored : .clear
    }

    /// Is this window macOS's in-use indicator?
    ///
    /// Four things at once, because at this window level the *cursor* is also
    /// a small window owned by the window server: the indicator is square
    /// (the arrow cursor is 28×40), on screen, and pinned to the top-right
    /// corner of a display. A square cursor parked in that exact corner is
    /// the one false positive left, it lasts as long as the pointer sits
    /// there, and it errs toward covering the body — the right way to be
    /// wrong.
    static func isIndicator(_ window: ScreenWatchSnapshot.Window, on displays: [CGRect]) -> Bool {
        guard window.level == indicatorLevel, window.onScreen else { return false }
        let side = window.frame.width
        guard side == window.frame.height, indicatorSide.contains(side) else { return false }
        return displays.contains { display in
            abs(display.maxX - window.frame.maxX) <= indicatorCornerSlack
                && abs(display.minY - window.frame.minY) <= indicatorCornerSlack
        }
    }
}

// MARK: - The sentinel

/// Reads `ScreenWatch` off the live system and publishes when it changes.
///
/// Polled, because nothing notifies: 2s while cards are on screen, nothing at
/// all when the screen is empty (there is no one to be shy in front of), plus
/// a fresh reading taken synchronously whenever the compositor is about to
/// draw. `CGWindowListCopyWindowInfo(.optionAll)` measured 3–5ms warm on this
/// Mac, which is why it is not simply run forever.
@MainActor
final class ScreenWatchSentinel: ObservableObject {
    static let shared = ScreenWatchSentinel(
        enabled: { ConfigFileStore.shared.current().shyWhenWatched }
    )

    /// What the last reading saw, whatever the setting says. Settings shows
    /// this even when shyness is off, so the switch can be understood before
    /// it is flipped.
    @Published private(set) var watch: ScreenWatch = .clear
    /// The one thing the compositor asks: should cards keep their bodies to
    /// themselves right now?
    @Published private(set) var isShy = false

    /// Fired when `isShy` flips, so the window system can re-render the cards
    /// already on screen. The queue is untouched — this is a rendering
    /// change, exactly like a topology rebuild.
    var onShyChanged: ((Bool) -> Void)?

    private let enabled: () -> Bool
    private var timer: Timer?
    private var holders: Set<PollHolder> = []

    private static let log = Logger(subsystem: "com.hausfold.trill", category: "screen-watch")

    init(enabled: @escaping () -> Bool) {
        self.enabled = enabled
    }

    /// Take a reading now and publish it. `notifying: false` is for the
    /// compositor's own render path, which is already about to draw with the
    /// value it gets back — firing the callback there would re-enter the
    /// render it was called from.
    @discardableResult
    func refresh(notifying: Bool = true) -> Bool {
        apply(ScreenWatch.evaluate(Self.readSystem()), notifying: notifying)
        return isShy
    }

    /// Who currently needs the reading kept fresh. Two of them, and they
    /// come and go independently — cards on screen, and a Settings window
    /// showing the live state — so the poll is held rather than switched:
    /// closing Settings must not stop the compositor's.
    enum PollHolder: String, Sendable {
        case compositor
        case settings
    }

    /// Poll while there is something on screen to be shy about, or someone
    /// watching the readout.
    func setPolling(_ on: Bool, by holder: PollHolder = .compositor) {
        if on { holders.insert(holder) } else { holders.remove(holder) }
        let wanted = !holders.isEmpty
        guard wanted != (timer != nil) else { return }
        guard wanted else {
            timer?.invalidate()
            timer = nil
            return
        }
        // No reading taken here: the compositor takes a fresh one whenever a
        // card arrives, which is the moment that matters, and the timer has
        // the rest.
        let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = 0.5
        self.timer = timer
    }

    private func apply(_ watch: ScreenWatch, notifying: Bool) {
        self.watch = watch
        let shy = enabled() && watch.isWatched
        guard shy != isShy else { return }
        isShy = shy
        Self.log.info("screen watch: \(shy ? "shy" : "clear", privacy: .public)")
        if notifying { onShyChanged?(shy) }
    }

    // MARK: - The Apple side

    /// One reading of the window server and the display list. The only part
    /// of this file that talks to macOS — and the only part with no actor to
    /// it: both CG calls are thread-safe, and keeping it free of the main
    /// actor is what lets it be exercised outside the app.
    nonisolated static func readSystem() -> ScreenWatchSnapshot {
        var snapshot = ScreenWatchSnapshot()

        let info = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        snapshot.windows = info.compactMap { entry in
            guard
                let level = entry[kCGWindowLayer as String] as? Int,
                // Only the indicator's own level is ever interesting, and
                // skipping the other ~230 windows keeps the poll cheap.
                level == ScreenWatch.indicatorLevel,
                let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
                let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { return nil }
            return ScreenWatchSnapshot.Window(
                level: level,
                frame: frame,
                onScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            )
        }

        for display in onlineDisplays() {
            if CGDisplayIsActive(display) != 0 {
                snapshot.displays.append(CGDisplayBounds(display))
            }
            // A hardware mirror (a display that can only ever mirror) says
            // nothing about who is watching; a mirror someone turned on does.
            if CGDisplayIsInMirrorSet(display) != 0, CGDisplayIsAlwaysInMirrorSet(display) == 0 {
                snapshot.mirroring = true
            }
        }
        return snapshot
    }

    nonisolated private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
