import SwiftUI

/// The banner's palette: one hue per `NotificationEvent.Kind`.
///
/// Trill ships no palette of its own — source hex lives in nebelung (see
/// AGENTS.md's routing table), and arrives here through
/// `~/.config/trill/theme.json`, written by whatever themes this machine
/// (haus, or a hand that likes a file). Absent that file, kinds ride the
/// system's semantic colors plus the accent asset, which is the same
/// "rides the system accent until the palette wiring lands" posture the
/// banner has always had — just per-kind now.
///
/// The file is one flat object of kind → hex:
///
///     { "ask": "#f5b58e", "fault": "#ed8fa9", "chat": "#8db4f3",
///       "pulse": "#9be0d5", "done": "#abe1a6", "note": "#b5bff8" }
///
/// Unknown keys are ignored, missing kinds keep their fallback, and a
/// malformed file keeps the last good theme — a typo must never turn the
/// banners grey.
struct BannerTheme: Equatable {
    var kindColors: [NotificationEvent.Kind: Color]

    func color(for kind: NotificationEvent.Kind) -> Color {
        kindColors[kind] ?? Self.fallback.kindColors[kind] ?? .accentColor
    }

    /// System semantics, no hex: close enough in spirit that an unthemed
    /// install still reads kind at a glance.
    static let fallback = BannerTheme(kindColors: [
        .ask: .orange,
        .fault: .red,
        .chat: .blue,
        .pulse: .teal,
        .done: .green,
        .note: .accentColor,
    ])

    /// Pure parse, so tests never touch the filesystem. `nil` means "not a
    /// theme" — the caller keeps whatever it had.
    static func parse(_ data: Data) -> BannerTheme? {
        guard let raw = try? JSONDecoder().decode([String: String].self, from: data) else {
            return nil
        }
        var colors = fallback.kindColors
        for (key, hex) in raw {
            guard let kind = NotificationEvent.Kind(rawValue: key),
                  let color = Color(trillHex: hex)
            else { continue }
            colors[kind] = color
        }
        return BannerTheme(kindColors: colors)
    }

    // MARK: - Loading

    /// The current theme, re-read when the file's mtime moves. A stat per
    /// render pass, not a watcher: banners render on arrival and restack,
    /// which is rare enough that polling here would cost more than it saves.
    @MainActor
    static func current(file: URL = AppPaths.themeFile) -> BannerTheme {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date
        if let cached, cachedMtime == mtime { return cached }
        cachedMtime = mtime
        if mtime != nil, let data = try? Data(contentsOf: file), let parsed = parse(data) {
            cached = parsed
        } else if mtime == nil || cached == nil {
            // File gone → fallback; malformed with a previous good theme →
            // keep the good one (neither branch fires).
            cached = fallback
        }
        return cached ?? fallback
    }

    @MainActor private static var cached: BannerTheme?
    @MainActor private static var cachedMtime: Date?
}

extension AppPaths {
    static var themeFile: URL { configDirectory.appendingPathComponent("theme.json") }
}

extension Color {
    /// `#rrggbb` / `rrggbb`. Anything else is refused, not guessed.
    init?(trillHex: String) {
        var hex = trillHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
