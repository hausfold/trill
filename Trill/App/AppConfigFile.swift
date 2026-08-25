import Foundation
import os.log

// MARK: - The settings file

/// Trill's app-level switches, as they live in `~/.config/trill/config.json`.
///
/// **The file is the source of truth.** Every switch in Settings reads from it
/// and writes back to it, so a hand-edited file and a clicked toggle are the
/// same act — there is no second copy in UserDefaults that could disagree, and
/// nothing to "sync". Anything a *rule* can express still belongs in
/// `rules.json`; this is only the handful of switches that are about the app
/// rather than about an event.
///
/// UserDefaults keeps exactly what a config file has no business holding:
/// window frames, which pane Settings was last on, and the one-shot flags the
/// Full Disk Access flow arms across a relaunch. Those are UI ephemera, not
/// settings.
struct AppConfig: Equatable, Sendable {
    /// On by default: a notification compositor that isn't running renders
    /// nothing, so a trill that doesn't come back after a reboot is just a
    /// broken trill.
    var launchAtLogin = true
    /// Off = nothing about any event ever touches disk.
    var persistHistory = true
    /// Experimental: always opt-in.
    var systemMirrorEnabled = false
    /// Needs `github.json` and a tunnel, so the switch alone promises
    /// nothing: opt-in.
    var githubBridgeEnabled = false

    /// The JSON key for each field. Spelled the way someone typing the file by
    /// hand would spell it — these names are user-facing surface, so renaming
    /// one silently drops whatever a user already wrote.
    enum Key {
        static let launchAtLogin = "launchAtLogin"
        static let persistHistory = "persistHistory"
        static let systemMirror = "systemMirror"
        static let githubBridge = "githubBridge"
    }

    init() {}

    /// Read from a decoded JSON object, keeping the default for anything the
    /// file doesn't name. A partial config.json is the normal case — the point
    /// of a settings file is that you write the one line you care about.
    init(json: [String: Any], defaults: AppConfig = AppConfig()) {
        self = defaults
        if let value = json[Key.launchAtLogin] as? Bool { launchAtLogin = value }
        if let value = json[Key.persistHistory] as? Bool { persistHistory = value }
        if let value = json[Key.systemMirror] as? Bool { systemMirrorEnabled = value }
        if let value = json[Key.githubBridge] as? Bool { githubBridgeEnabled = value }
    }

    /// Every key, at its current value — what gets merged back into the file
    /// on a write. Written in full rather than as a delta so the file is
    /// self-documenting: open it and every switch trill has is in there.
    var json: [String: Any] {
        [
            Key.launchAtLogin: launchAtLogin,
            Key.persistHistory: persistHistory,
            Key.systemMirror: systemMirrorEnabled,
            Key.githubBridge: githubBridgeEnabled,
        ]
    }
}

// MARK: - The store

/// Loads `~/.config/trill/config.json`, watches it, and writes it back.
///
/// The same shape as `RulesWatcher` and for the same reason: the file can
/// change under a running trill — a hand-edit, `haus rebuild`, another
/// machine's dotfiles landing — and the app should follow it rather than
/// overwrite it at the next click.
///
/// Thread-safe by one serial queue, because the answer is needed from three
/// places at once: SwiftUI on the main actor, the provider supervisor off it,
/// and the file-system source itself.
final class ConfigFileStore: @unchecked Sendable {
    static let shared = ConfigFileStore(file: AppPaths.configFile)

    private let file: URL
    private let queue = DispatchQueue(label: "com.hausfold.trill.config")
    private var config = AppConfig()
    /// Every key the file had, decoded but not interpreted. A write merges
    /// into this rather than replacing it, so a key trill doesn't know —
    /// something a newer build writes, or a comment-ish field someone added —
    /// survives a toggle instead of being quietly deleted.
    private var raw: [String: Any] = [:]
    private var source: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1
    private var observer: (@Sendable (AppConfig) -> Void)?

    private static let log = Logger(subsystem: "com.hausfold.trill", category: "config")

    init(file: URL) {
        self.file = file
        queue.sync { load() }
    }

    /// The current settings. Callable from anywhere, including off the main
    /// actor — the GitHub provider's supervisor asks from its own task.
    func current() -> AppConfig {
        queue.sync { config }
    }

    /// Start following the file. Separate from `init` so a test can construct
    /// a store against a temp file without arming a watcher.
    ///
    /// `onChange` fires only when the file's *content* differs from what the
    /// store already holds, which is what makes trill's own writes silent: the
    /// write lands, the watcher fires, the reload finds the same values, and
    /// nothing is republished. No echo, no flag, no race.
    func start(onChange: @escaping @Sendable (AppConfig) -> Void) {
        queue.sync {
            observer = onChange
            load()
            watch()
        }
    }

    /// True when the file is a symlink into the Nix store — i.e. this Mac's
    /// desktop generated it. Writing there fails (the store is read-only) and
    /// would be wrong even if it didn't: the next rebuild puts the generated
    /// file straight back, so a toggle isn't lost so much as silently
    /// reverted, which is worse. Settings shows those rows read-only instead.
    ///
    /// The same rule pounce applies to its own `config.json`
    /// (`ConfigMode.isNixManaged`).
    var isManagedExternally: Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)
        else { return false }
        return target.hasPrefix("/nix/store/")
    }

    var fileURL: URL { file }

    /// Apply a change and write the whole file back. Returns the error if the
    /// write failed, so Settings can say so rather than showing a switch that
    /// moved and a file that didn't.
    @discardableResult
    func update(_ mutate: @Sendable (inout AppConfig) -> Void) -> Error? {
        queue.sync {
            var updated = config
            mutate(&updated)
            guard updated != config else { return nil }
            config = updated
            do {
                try write(updated)
                return nil
            } catch {
                Self.log.error("config.json write failed: \(error.localizedDescription, privacy: .public)")
                return error
            }
        }
    }

    // MARK: - Disk

    private func load() {
        guard let data = try? Data(contentsOf: file) else {
            // No file yet is not an error — it means every setting is at its
            // default, which is exactly what an absent key already means.
            raw = [:]
            config = AppConfig()
            return
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            // A typo must never turn the app's switches off underneath
            // someone. Keep what's already loaded, same as rules.json.
            Self.log.error("config.json isn't a JSON object — keeping the previous settings")
            return
        }
        raw = json
        let reloaded = AppConfig(json: json)
        guard reloaded != config else { return }
        config = reloaded
        observer?(reloaded)
    }

    private func write(_ config: AppConfig) throws {
        guard !isManagedExternally else { throw ConfigWriteError.managedExternally }
        var merged = raw
        for (key, value) in config.json { merged[key] = value }
        raw = merged
        let data = try JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Atomic, so a reader (this app's own watcher included) never sees a
        // half-written file. The rename that makes it atomic is also what the
        // watcher has to re-arm after — `watch()` handles that.
        try (data + Data("\n".utf8)).write(to: file, options: .atomic)
        // The file may not have existed when the watcher armed, and an atomic
        // write replaces the inode either way: re-arm against what is there
        // now, or the next hand-edit goes unnoticed.
        watch()
    }

    private func watch() {
        source?.cancel()
        source = nil
        if watchedFD >= 0 { close(watchedFD); watchedFD = -1 }
        // Nothing to watch yet. `start()` is called again after any write, and
        // a config that has never been written is all defaults anyway.
        guard observer != nil else { return }

        watchedFD = open(file.path, O_EVTONLY)
        guard watchedFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: watchedFD,
            eventMask: [.write, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            self?.load()
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self?.watch()
            }
        }
        src.setCancelHandler { [fd = watchedFD] in if fd >= 0 { close(fd) } }
        src.resume()
        source = src
    }
}

enum ConfigWriteError: LocalizedError {
    case managedExternally

    var errorDescription: String? {
        switch self {
        case .managedExternally:
            return "config.json is generated by this Mac's desktop — change it there and rebuild."
        }
    }
}
