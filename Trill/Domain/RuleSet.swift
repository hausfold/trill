import Foundation

/// What the policy engine decides to do with one event.
enum DeliveryDecision: Equatable, Sendable {
    /// Draw a banner now (and record to the inbox), on the display the rule
    /// named. `.primary` unless a rule said otherwise, which is where macOS
    /// puts its own and where every banner went before routing existed.
    case banner(DisplayTarget)
    /// No banner; the event lands in the inbox only.
    case inboxOnly
    /// Batch into a named digest, flushed on the digest's schedule.
    case digest(String)
    /// Straight to the ledge as a fin — no banner, ever. The one route that
    /// draws a *question* without interrupting: a Focus is the user saying
    /// "not now", and an `ask` is the one kind that cannot simply be filed
    /// away, because somebody is blocked on the answer. So it goes where an
    /// unanswered question already goes when its clock runs out.
    ///
    /// Only an `ask` may take this route (`PolicyEngine` coerces anything
    /// else to `.inboxOnly`, `BannerQueue.park` refuses it a second time):
    /// the ledge is the strip of things waiting on you, and a `note` filed
    /// there would be a fin nobody can answer.
    case ledge(DisplayTarget)
    /// Discard entirely (never persisted).
    case drop

    /// Did this decision put the event on a screen? Asked by everything that
    /// cares *whether* a banner was drawn and not *where* — a question that
    /// stopped being expressible as `== .banner` the moment the case grew a
    /// display target.
    ///
    /// A fin is deliberately **not** a banner here. It is on a screen, but it
    /// is on the *edge* of one, unread until somebody deals with it — which
    /// is exactly what the inbox's unread count is for.
    var isBanner: Bool {
        if case .banner = self { return true }
        return false
    }

    /// Did this decision park a question on the ledge?
    var isLedge: Bool {
        if case .ledge = self { return true }
        return false
    }
}

/// Declarative filtering, loaded from `~/.config/trill/rules.json`.
/// First matching rule wins; no rule → banner. Kept deliberately small:
/// common cases stay declarative, anything fancier is a future opt-in hook,
/// never an implicit shell-out per event.
struct RuleSet: Codable, Sendable, Equatable {
    struct Rule: Codable, Sendable, Equatable {
        struct Match: Codable, Sendable, Equatable {
            /// Exact source slug/bundle id (case-insensitive).
            var source: String?
            /// Substring match on the normalized title (case-insensitive).
            var titleContains: String?
            /// Rule applies only at or below this urgency.
            var urgencyAtMost: NotificationEvent.Urgency?
            /// Exact event kind (`ask`, `fault`, `chat`, `pulse`, `done`,
            /// `note`). The axis routing is usually written against — "faults
            /// on the big screen" is a sentence about kind, not about source.
            var kind: NotificationEvent.Kind?

            func matches(_ event: NotificationEvent) -> Bool {
                if let source, event.source != source.lowercased() { return false }
                if let titleContains,
                   !event.title.localizedCaseInsensitiveContains(titleContains) { return false }
                if let urgencyAtMost, event.urgency > urgencyAtMost { return false }
                if let kind, event.kind != kind { return false }
                return true
            }
        }

        enum Delivery: Codable, Sendable, Equatable {
            case banner
            case inbox
            case digest(String)
            case drop

            // Encoded as {"delivery": "digest", "digest": "work"} alongside
            // the rule's other keys — flat JSON a human writes by hand. The
            // `Rule` extension below is what makes "alongside" true; without
            // it these keys land one level down and the file won't parse.
        }

        var match: Match
        var delivery: Delivery
        /// Which display a bannered match draws on. Written flat beside
        /// `delivery`, like `digest`. Nil means `.primary`; it is ignored on
        /// a rule that banners nothing, because a digest card is drawn by the
        /// scheduler hours later and an inbox row is drawn on no screen at
        /// all.
        var display: DisplayTarget?
    }

    struct QuietHours: Codable, Sendable, Equatable {
        /// Minutes since local midnight; a window may cross midnight
        /// (start 1320 / end 420 = 22:00–07:00).
        var startMinute: Int
        var endMinute: Int

        func contains(minuteOfDay minute: Int) -> Bool {
            if startMinute == endMinute { return false }
            if startMinute < endMinute {
                return minute >= startMinute && minute < endMinute
            }
            return minute >= startMinute || minute < endMinute
        }

        /// The same question against a real instant. Two callers ask it — the
        /// policy engine demoting a banner, the digest scheduler holding a
        /// flush — and they must never disagree about where the window is.
        func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
            let comps = calendar.dateComponents([.hour, .minute], from: date)
            return contains(minuteOfDay: (comps.hour ?? 0) * 60 + (comps.minute ?? 0))
        }
    }

    /// What each kind of event does while macOS is in a Focus.
    ///
    /// Read, never written: trill does not turn a Focus on or off — that
    /// dial belongs to the desktop (haus's "Hush") and to the user. See
    /// `SystemFocus`.
    ///
    /// Written flat, as a kind → behavior map with one reserved key:
    ///
    ///     "focus": { "default": "inbox", "fault": "banner", "ask": "ledge" }
    ///
    /// …which is also the shipped default, so a file that never mentions
    /// `focus` gets it. The three behaviors it names are the whole feature:
    /// **chatter stops interrupting, faults still land, and questions park on
    /// the ledge** rather than being swallowed — because somebody is blocked
    /// on a question, and a Focus is not a reason to strand them.
    struct FocusPolicy: Sendable, Equatable {
        /// What a Focus may do to an event that would otherwise banner. It
        /// can quieten one and it can move one sideways; it can never turn a
        /// quiet event into a loud one, because a rule that already said
        /// "inbox" said it about every hour of the day.
        enum Behavior: String, Codable, Sendable {
            /// Draw it anyway. What a Focus is *not* allowed to swallow.
            case banner
            /// File it. The inbox has it, unread, and nothing appears.
            case inbox
            /// Park it as a fin — asks only.
            case ledge
        }

        /// What a kind the map doesn't name does.
        var fallback: Behavior
        /// Per-kind overrides.
        var kinds: [NotificationEvent.Kind: Behavior]

        /// The key a user writes for `fallback`. Not a kind, so it can never
        /// collide with one.
        static let fallbackKey = "default"

        /// trill's own reading of what a Focus means. Everything quietens;
        /// a fault is the exception that always lands; a question parks
        /// instead of vanishing.
        static let standard = FocusPolicy(
            fallback: .inbox,
            kinds: [.fault: .banner, .ask: .ledge]
        )

        init(fallback: Behavior = .inbox, kinds: [NotificationEvent.Kind: Behavior] = [:]) {
            self.fallback = fallback
            self.kinds = kinds
        }

        func behavior(for kind: NotificationEvent.Kind) -> Behavior {
            kinds[kind] ?? fallback
        }

        /// Two policies are the same policy when they decide the same way
        /// about every kind — not when their dictionaries happen to match.
        /// `Kind` is `CaseIterable`, so that is the whole of what a policy
        /// can be asked, and it is what makes the round trip through JSON
        /// exact: the encoder writes every kind out in full, so a `{fault:
        /// banner}` map comes back as six explicit entries that decide
        /// identically.
        static func == (lhs: Self, rhs: Self) -> Bool {
            NotificationEvent.Kind.allCases.allSatisfy {
                lhs.behavior(for: $0) == rhs.behavior(for: $0)
            }
        }
    }

    var rules: [Rule]
    var quietHours: QuietHours?
    /// How a Focus routes each kind, or nil for `FocusPolicy.standard`.
    /// Whether trill looks at Focus at all is a *switch*, not a rule — it
    /// lives in `config.json` as `focusAware`, beside shyness, because it is
    /// about the app and not about an event.
    var focus: FocusPolicy?
    /// Named ways to find out whether a parked ask has answered itself —
    /// see `Resolver`. Declared here and only here: `--until` names one of
    /// these, and a name that isn't in this map resolves nothing.
    var resolvers: [String: Resolver]?

    static let empty = RuleSet(rules: [], quietHours: nil)

    /// The resolver `--until NAME` meant, if the user declared it.
    func resolver(named name: String) -> Resolver? { resolvers?[name] }
}

/// A rule's `delivery` is written **flat**, beside `match`:
///
///     { "match": { "source": "ads" }, "delivery": "drop" }
///     { "match": { "source": "slack" }, "delivery": "digest", "digest": "work" }
///
/// which is the shape the README documents and the shape anyone writing this
/// file by hand produces. That takes a hand-rolled `Codable`: the synthesized
/// one would hand `Delivery` the *value* of the `delivery` key and expect it
/// to be an object of its own, so a plain `"drop"` failed to decode and the
/// watcher fell back to the previous (empty) rule set — every rule in the
/// file silently ignored, one log line the user never sees.
///
/// The old round-trip test passed straight through that: it encoded and
/// decoded with the same nested convention, and never read a line of the
/// documented format.
extension RuleSet.Rule {
    private enum CodingKeys: String, CodingKey { case match, display, delivery }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        match = try container.decodeIfPresent(Match.self, forKey: .match) ?? Match()
        display = try container.decodeIfPresent(DisplayTarget.self, forKey: .display)
        // A rule may name only *where*: `{"match": …, "display": "builtin"}`
        // is a routing rule, and making it also write `"delivery": "banner"`
        // would be ceremony for the commonest thing anyone writes. `delivery`
        // stays required everywhere else, so a mistyped key still fails the
        // file loudly instead of quietly becoming a banner rule.
        if display != nil, !container.contains(.delivery) {
            delivery = .banner
        } else {
            // The same decoder, not a nested one: `delivery`/`digest` are the
            // rule's own keys.
            delivery = try Delivery(from: decoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(match, forKey: .match)
        try container.encodeIfPresent(display, forKey: .display)
        try delivery.encode(to: encoder)
    }
}

extension RuleSet.Rule.Delivery {
    private enum CodingKeys: String, CodingKey { case delivery, digest }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .delivery) {
        case "banner": self = .banner
        case "inbox": self = .inbox
        case "drop": self = .drop
        case "digest":
            self = .digest(try c.decodeIfPresent(String.self, forKey: .digest) ?? "default")
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .delivery, in: c,
                debugDescription: "unknown delivery '\(other)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .banner: try c.encode("banner", forKey: .delivery)
        case .inbox: try c.encode("inbox", forKey: .delivery)
        case .drop: try c.encode("drop", forKey: .delivery)
        case .digest(let name):
            try c.encode("digest", forKey: .delivery)
            try c.encode(name, forKey: .digest)
        }
    }
}

/// `focus` is a flat kind → behavior map with one reserved key, because that
/// is what somebody types:
///
///     "focus": { "default": "inbox", "fault": "banner", "ask": "ledge" }
///
/// Two rules make it safe to write only the line you care about. What the
/// file names is **layered over `FocusPolicy.standard`**, so `{"chat":
/// "banner"}` keeps faults landing and asks parking — the same promise
/// `config.json` makes, where a key the file doesn't name is that key at its
/// default. And a kind trill has never heard of is a *rejected file*, not a
/// silently ignored line: `RulesWatcher` keeps the last good set and says so,
/// which is the only way a typo'd `"faults"` ever gets noticed.
extension RuleSet.FocusPolicy: Codable {
    /// The map's keys are data (kind names), not a fixed set of fields, so
    /// the container is keyed by whatever the file says.
    private struct MapKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: MapKey.self)
        var policy = Self.standard
        for key in container.allKeys {
            let behavior = try container.decode(Behavior.self, forKey: key)
            guard key.stringValue != Self.fallbackKey else {
                policy.fallback = behavior
                continue
            }
            guard let kind = NotificationEvent.Kind(rawValue: key.stringValue) else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container,
                    debugDescription: "unknown event kind '\(key.stringValue)' under focus"
                )
            }
            policy.kinds[kind] = behavior
        }
        self = policy
    }

    /// Every kind, at its effective behavior — written in full rather than as
    /// a delta, for the reason `AppConfig.json` is: open the file and the
    /// whole policy is in there. It also makes the round trip exact, which a
    /// delta over `standard` could not be.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: MapKey.self)
        try container.encode(fallback, forKey: MapKey(Self.fallbackKey))
        for kind in NotificationEvent.Kind.allCases {
            try container.encode(behavior(for: kind), forKey: MapKey(kind.rawValue))
        }
    }
}
