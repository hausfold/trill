import AppKit
import Foundation

/// The in-product door to trill's bug form — the menu bar's *Report a Bug…*
/// and `trill report`, which are the same five lines by two routes.
///
/// There is no telemetry in anything we ship and there never will be, so the
/// issue form is not one feedback channel among several — it is the only one
/// (workshop `docs/bug-reports.md`). A form nobody can reach from inside the
/// app is a channel that exists on paper, and "open github.com/hausfold, pick
/// the right repo of nine, find its Issues tab" is three steps somebody whose
/// banners stopped working has agreed to none of.
///
/// **Why `?template=bug.yml` and not `?title=&body=`.** A `body=` prefill opens
/// GitHub's *blank* editor and walks straight past the designed form — its
/// fields, its "wrong repo? file it anyway" preamble, and the labels it
/// applies. Nothing fails; the reporter just never sees any of it. The query
/// has to name the template.
///
/// **Why these five lines and not `trill doctor`.** trill's doctor answers one
/// specific question — which apps are notifying twice — and it needs Full Disk
/// Access to answer it at all. It is the right paste for a double-banner report
/// and the wrong one for every other kind, and a door that stalls on a
/// permission the reporter may not have granted is a door that doesn't open. So
/// the prefill is the environment, including *whether* that grant is in place,
/// which is itself one of the commonest answers. The form still asks for
/// `trill doctor` on top, for the reports where it means something.
enum BugReport {
    static let repository = "hausfold/trill"
    static let formURL = "https://github.com/\(repository)/issues/new"

    /// Above this, drop the prefill and use the pasteboard instead. GitHub
    /// serves a URL of roughly 8 KB and refuses past it; the margin is for the
    /// rest of the query and for a block that grows later.
    static let maximumURLLength = 6000

    // MARK: - The block

    /// Pure, so the wording is pinned by a test rather than by reading it.
    ///
    /// Deliberately short, and deliberately free of anything a reporter would
    /// want to redact: no bundle path (it carries their username), nothing off
    /// their inbox, no rule bodies. This lands in a public issue — they see it
    /// before they press Submit, but they see it in a field the app filled in
    /// for them, which is a weaker kind of consent than typing it.
    static func diagnostics(
        version: String,
        operatingSystem: String,
        model: String,
        install: InstallLocation,
        fullDiskAccess: Bool
    ) -> String {
        """
        trill \(version)
        macOS \(operatingSystem)
        \(model)
        installed: \(install.description)
        Full Disk Access: \(fullDiskAccess ? "granted" : "not granted")
        """
    }

    /// The live one. Cheap and synchronous on purpose — a menu row that has to
    /// await anything is a menu row that can hang while the menu is open.
    static func diagnostics() -> String {
        diagnostics(
            version: currentVersion,
            operatingSystem: currentOperatingSystem,
            model: currentModel,
            install: InstallLocation.detectLive(),
            fullDiskAccess: NotificationSettingsAudit.unreadableReason() == nil
        )
    }

    static var currentVersion: String {
        guard let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty,
              version != "$(MARKETING_VERSION)"
        else {
            return "dev"
        }
        return version
    }

    /// `26.0.1 (25A354)` — the pair Apple's own bug reports ask for, because a
    /// build number distinguishes two OSes that answer the same to a user.
    static var currentOperatingSystem: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let short = "\(version.majorVersion).\(version.minorVersion)"
            + (version.patchVersion > 0 ? ".\(version.patchVersion)" : "")
        guard let build = sysctl("kern.osversion") else { return short }
        return "\(short) (\(build))"
    }

    /// `Mac16,10`. The marketing name reads better and needs a round trip to
    /// Apple to obtain, so this is the identifier — which is what a maintainer
    /// looks up anyway.
    static var currentModel: String { sysctl("hw.model") ?? "unknown Mac" }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        // sysctl reports the length *including* the NUL, which would otherwise
        // ride along as a U+0000 on the end of the identifier.
        let value = String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        return value.isEmpty ? nil : value
    }

    // MARK: - Where this copy came from

    /// How trill got onto this Mac, to the resolution a maintainer can act on
    /// and no further.
    ///
    /// Reported as a *category*, never as the bundle path: `~/Applications` and
    /// a Nix profile path both carry the reporter's username, and a field the
    /// app fills in for them is not the place to put it.
    ///
    /// This is coarser than perch's `InstallKind`, on purpose. perch has to
    /// tell a cask copy from a desktop copy because it *acts* on the answer (it
    /// offers to replace its own bundle for exactly one cohort). trill only has
    /// to say enough that "it works from a terminal but not when the desktop
    /// starts it" is a sentence somebody can begin.
    enum InstallLocation: String, CaseIterable, Equatable {
        case nix
        case homebrew
        case applications
        case userApplications
        case elsewhere

        var description: String {
            switch self {
            case .nix: return "Nix store"
            case .homebrew: return "Homebrew cask"
            case .applications: return "/Applications"
            case .userApplications: return "~/Applications"
            case .elsewhere: return "somewhere else"
            }
        }

        /// A cask's `app` stanza MOVES the bundle to /Applications, so the path
        /// alone can't tell a cask copy from a dragged one — brew's Caskroom
        /// staging directory survives the move and breaks the tie.
        static func detect(bundlePath: String, home: String, hasCaskReceipt: Bool) -> InstallLocation {
            if bundlePath.hasPrefix("/nix/store/") { return .nix }
            if hasCaskReceipt { return .homebrew }
            if bundlePath.hasPrefix("\(home)/Applications/") { return .userApplications }
            if bundlePath.hasPrefix("/Applications/") { return .applications }
            return .elsewhere
        }

        static let caskReceiptPaths = [
            "/opt/homebrew/Caskroom/trill",
            "/usr/local/Caskroom/trill",
        ]

        static func detectLive(fileManager: FileManager = .default) -> InstallLocation {
            detect(
                bundlePath: Bundle.main.bundleURL.resolvingSymlinksInPath().path,
                home: NSHomeDirectory(),
                hasCaskReceipt: caskReceiptPaths.contains { fileManager.fileExists(atPath: $0) }
            )
        }
    }

    // MARK: - The URL

    /// Where the door goes, and whether the block had to travel by pasteboard.
    struct Destination: Equatable {
        var url: URL
        /// Non-nil when the block was too long to prefill: the caller puts this
        /// on the pasteboard and says so, rather than opening a form with a
        /// field it silently declined to fill.
        var pasteboard: String?
    }

    /// Pure, so the encoding and the length guard are testable without opening
    /// anything.
    ///
    /// The query is assembled by hand rather than through
    /// `URLComponents.queryItems`, which encodes with
    /// `CharacterSet.urlQueryAllowed` — a set that *contains* `+` and therefore
    /// leaves it literal, where the receiving server decodes it back as a
    /// space. RFC 3986 unreserved characters pass; everything else is encoded.
    static func destination(diagnostics: String) -> Destination {
        let short = "\(formURL)?template=bug.yml"
        let full = "\(short)&diagnostics=\(percentEncoded(diagnostics))"

        if full.count <= maximumURLLength, let url = URL(string: full) {
            return Destination(url: url, pasteboard: nil)
        }
        // Unreachable via `URL(string:)` failing — the short form is a literal —
        // but a door that can silently do nothing is worse than one that opens
        // the repo's Issues tab.
        guard let url = URL(string: short) else {
            return Destination(url: URL(string: "https://github.com/\(repository)/issues")!, pasteboard: diagnostics)
        }
        return Destination(url: url, pasteboard: diagnostics)
    }

    static func percentEncoded(_ value: String) -> String {
        var out = ""
        for byte in Array(value.utf8) {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39,  // A-Z a-z 0-9
                 0x2D, 0x2E, 0x5F, 0x7E:                 // - . _ ~
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    // MARK: - The doors

    /// The menu row's whole body.
    ///
    /// The pasteboard branch belongs to this door alone: the menu has nowhere
    /// else to put an over-long block, while `trill report` has already printed
    /// it to stdout where the reporter can select it. Clobbering a pasteboard
    /// nobody asked us to touch is worth doing once, silently, only when the
    /// alternative is a form field the app declined to fill without saying so.
    @MainActor
    static func open() {
        let destination = destination(diagnostics: diagnostics())
        if let pasteboard = destination.pasteboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pasteboard, forType: .string)
        }
        openInBrowser(destination.url)
    }

    /// Hand a URL to whatever opens https here.
    ///
    /// Lives beside the rest of this door so `trill report` — which runs in the
    /// CLI personality, with no NSApplication and no AppKit import of its own —
    /// has one call to make rather than an import to grow.
    static func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
