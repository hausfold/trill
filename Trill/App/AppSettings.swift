import Foundation
import Combine

/// UserDefaults-backed settings (perch's `AppSettings` shape). Anything a
/// rule can express lives in `~/.config/trill/rules.json` instead — settings
/// here are app-level switches only.
@MainActor
final class AppSettings: ObservableObject {
    /// On by default: a notification compositor that isn't running renders
    /// nothing, so a trill that doesn't come back after a reboot is just a
    /// broken trill. `init` seeds the actual `SMAppService` registration on
    /// first launch (see below) — one switch here undoes it.
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            if launchAtLogin {
                SystemIntegration.registerAsLoginItem()
            } else {
                SystemIntegration.unregisterLoginItem()
            }
        }
    }

    /// Off = nothing about any event ever touches disk.
    @Published var persistHistory: Bool {
        didSet { defaults.set(persistHistory, forKey: Keys.persistHistory) }
    }

    @Published var systemMirrorEnabled: Bool {
        didSet {
            defaults.set(systemMirrorEnabled, forKey: Keys.systemMirror)
            // Toggling this is typically followed by a Full Disk Access grant,
            // which macOS surfaces as a native "Quit & Reopen" prompt — the
            // process can die before CFPreferences' async flush lands, so
            // force it to disk now rather than losing the toggle on relaunch.
            defaults.synchronize()
        }
    }

    /// Set when FDA assistant flow is triggered so that if the user or macOS
    /// quits & relaunches Trill, Settings re-opens automatically to show status.
    @Published var reopenSettingsOnLaunch: Bool {
        didSet {
            defaults.set(reopenSettingsOnLaunch, forKey: Keys.reopenSettingsOnLaunch)
            defaults.synchronize()
        }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let launchAtLogin = "launchAtLogin"
        static let persistHistory = "persistHistory"
        static let systemMirror = "systemMirrorEnabled"
        static let reopenSettingsOnLaunch = "reopenSettingsOnLaunch"
        static let loginItemBundlePath = "loginItemBundlePath"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.launchAtLogin: true,
            Keys.persistHistory: true,
            Keys.systemMirror: false, // experimental: always opt-in
            Keys.reopenSettingsOnLaunch: false,
        ])
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        persistHistory = defaults.bool(forKey: Keys.persistHistory)
        systemMirrorEnabled = defaults.bool(forKey: Keys.systemMirror)
        reopenSettingsOnLaunch = defaults.bool(forKey: Keys.reopenSettingsOnLaunch)

        syncLoginItemRegistration()
    }

    /// A registered default is a value, not an action — `didSet` never fires
    /// from `init` — so the *first* launch has to register the login item by
    /// hand. Keyed on the bundle path rather than a one-shot flag, so a build
    /// that later moves (dev-install, or a drag from Downloads to
    /// /Applications) re-registers instead of leaving the user's Login Items
    /// pointing at a path that no longer exists.
    ///
    /// It deliberately does *not* re-register just because the entry is
    /// missing at an unchanged path: a user who removed trill in System
    /// Settings > General > Login Items meant it, and an app that silently
    /// puts itself back is the exact thing that makes that pane untrustworthy.
    private func syncLoginItemRegistration() {
        // An XCTest host *is* Trill.app, run out of DerivedData — registering
        // from there aims the user's Login Items at a build directory.
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        guard launchAtLogin else { return }

        let bundlePath = Bundle.main.bundleURL.path
        guard defaults.string(forKey: Keys.loginItemBundlePath) != bundlePath else { return }
        SystemIntegration.registerAsLoginItem()
        defaults.set(bundlePath, forKey: Keys.loginItemBundlePath)
    }
}
