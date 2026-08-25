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
    /// Discard entirely (never persisted).
    case drop

    /// Did this decision put the event on a screen? Asked by everything that
    /// cares *whether* a banner was drawn and not *where* — a question that
    /// stopped being expressible as `== .banner` the moment the case grew a
    /// display target.
    var isBanner: Bool {
        if case .banner = self { return true }
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

    var rules: [Rule]
    var quietHours: QuietHours?
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
