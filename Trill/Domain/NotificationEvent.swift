import Foundation

/// The one event model every provider maps into and every surface renders
/// from. Provider-specific shapes (socket JSON, usernoted rows, future
/// webhook payloads) are translated at the provider boundary and never leak
/// past it.
struct NotificationEvent: Codable, Sendable, Identifiable, Equatable {
    enum Urgency: String, Codable, Sendable, Comparable {
        case low, normal, critical

        private var rank: Int {
            switch self {
            case .low: 0
            case .normal: 1
            case .critical: 2
            }
        }

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    /// How much of the event may be drawn on a shared screen. `redacted`
    /// banners show source + title only; the body stays inbox-only.
    enum Privacy: String, Codable, Sendable {
        case visible, redacted
    }

    /// An action the *source* can honor. Providers advertise what they can
    /// actually do (the family's capability pattern); the renderer never invents
    /// buttons the source can't back.
    struct Action: Codable, Sendable, Equatable, Identifiable {
        enum Kind: String, Codable, Sendable {
            /// Activate the app the event came from.
            case openApp = "open_app"
            /// Open a URL carried in the event.
            case openURL = "open_url"
            /// Run a user-configured hook command (opt-in, rules-declared).
            case command
            /// Open the helper that walks the user through turning Apple's
            /// own banners off. `target` names the apps to walk: one bundle
            /// id, or several comma-joined when one banner stands for a whole
            /// worklist. A nil target names nothing, and the helper falls back
            /// to the apps `rules.json` lists — never to every app on the Mac.
            /// trill never writes those settings itself — this only opens
            /// System Settings and stands beside it.
            case silenceNative = "silence_native"
        }

        var id: String
        var label: String
        var kind: Kind
        /// Kind-specific payload: a bundle id, a URL string, a hook name.
        var target: String?

        /// Schemes trill will hand to the workspace. Anything else is a
        /// refused click, so `hasDefaultAction` and `ActionRouter` both ask
        /// here rather than each keeping their own list.
        static let openableSchemes = ["https", "http", "file"]

        /// Would an `open_url` action with this target actually open?
        static func opensAsURL(_ target: String?) -> Bool {
            guard let target, let url = URL(string: target) else { return false }
            return openableSchemes.contains(url.scheme?.lowercased() ?? "")
        }
    }

    var id: String
    /// Short slug (`deploy`, `pounce`) or reverse-dns bundle id for mirrored
    /// system events (`com.tinyspeck.slackmacgap`).
    var source: String
    var timestamp: Date

    var title: String
    var subtitle: String?
    var body: String?
    /// SF Symbol name for the banner glyph.
    var symbol: String?

    /// Events sharing a thread coalesce under burst pressure.
    var thread: String?
    var urgency: Urgency
    var privacy: Privacy

    var actions: [Action]
    var metadata: [String: String]

    init(
        id: String = UUID().uuidString,
        source: String,
        timestamp: Date = .now,
        title: String,
        subtitle: String? = nil,
        body: String? = nil,
        symbol: String? = nil,
        thread: String? = nil,
        urgency: Urgency = .normal,
        privacy: Privacy = .visible,
        actions: [Action] = [],
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.source = source
        self.timestamp = timestamp
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.symbol = symbol
        self.thread = thread
        self.urgency = urgency
        self.privacy = privacy
        self.actions = actions
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id, source, timestamp, title, subtitle, body, symbol, thread, urgency, privacy, actions, metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.source = try container.decodeIfPresent(String.self, forKey: .source) ?? "cli"
        self.timestamp = try container.decodeIfPresent(Date.self, forKey: .timestamp) ?? .now
        self.title = try container.decode(String.self, forKey: .title)
        self.subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        self.body = try container.decodeIfPresent(String.self, forKey: .body)
        self.symbol = try container.decodeIfPresent(String.self, forKey: .symbol)
        self.thread = try container.decodeIfPresent(String.self, forKey: .thread)
        self.urgency = try container.decodeIfPresent(Urgency.self, forKey: .urgency) ?? .normal
        self.privacy = try container.decodeIfPresent(Privacy.self, forKey: .privacy) ?? .visible
        self.actions = try container.decodeIfPresent([Action].self, forKey: .actions) ?? []
        self.metadata = try container.decodeIfPresent([String: String].self, forKey: .metadata) ?? [:]
    }
}

extension NotificationEvent {
    /// Does clicking this event do anything? Every surface that offers a
    /// click asks *this* before drawing itself as pressable, and
    /// `ActionRouter.performDefault` refuses the same set — trill draws no
    /// dead buttons, so the two have to answer identically.
    ///
    /// It mirrors `performDefault` exactly: the *first* declared action is the
    /// only one a click runs, so only that one is inspected. A `command`
    /// action is not pressable because hooks aren't wired yet (PRD M2) and the
    /// router only logs; a `open_url` whose target isn't a scheme the router
    /// will open is refused here for the same reason it is refused there.
    ///
    /// The one thing it can't promise is that a bundle id resolves to an
    /// installed app — that's a LaunchServices lookup, and this stays pure.
    /// A click on `source: "deploy.prod"` with no such app gets as far as the
    /// router and is logged there; the button is honest about intent, not
    /// about what's installed.
    var hasDefaultAction: Bool {
        guard let action = actions.first else { return source.contains(".") }
        switch action.kind {
        case .openApp, .silenceNative: return true
        case .openURL: return Action.opensAsURL(action.target)
        case .command: return false
        }
    }

    /// Field caps: a banner is a glance, not a document. Oversized input is
    /// truncated here, once, so no downstream surface needs its own limits.
    enum Limits {
        static let title = 200
        static let subtitle = 200
        static let body = 1000
        static let metadataPairs = 32
    }

    /// Canonical form used for dedupe, persistence, and rendering.
    /// Whitespace-trimmed, length-capped, empty optionals dropped.
    func normalized() -> NotificationEvent {
        var event = self
        event.source = source.trimmed(cap: 100).lowercased()
        event.title = title.trimmed(cap: Limits.title)
        event.subtitle = subtitle?.trimmed(cap: Limits.subtitle).nonEmpty
        event.body = body?.trimmed(cap: Limits.body).nonEmpty
        event.symbol = symbol?.trimmed(cap: 100).nonEmpty
        event.thread = thread?.trimmed(cap: 100).nonEmpty
        if event.metadata.count > Limits.metadataPairs {
            event.metadata = Dictionary(
                uniqueKeysWithValues: event.metadata.sorted { $0.key < $1.key }
                    .prefix(Limits.metadataPairs)
                    .map { ($0.key, $0.value) }
            )
        }
        return event
    }
}

private extension String {
    func trimmed(cap: Int) -> String {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > cap ? String(t.prefix(cap)) : t
    }

    var nonEmpty: String? { isEmpty ? nil : self }
}
