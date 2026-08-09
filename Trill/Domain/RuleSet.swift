import Foundation

/// What the policy engine decides to do with one event.
enum DeliveryDecision: Equatable, Sendable {
    /// Draw a banner now (and record to the inbox).
    case banner
    /// No banner; the event lands in the inbox only.
    case inboxOnly
    /// Batch into a named digest, flushed on the digest's schedule.
    case digest(String)
    /// Discard entirely (never persisted).
    case drop
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

            func matches(_ event: NotificationEvent) -> Bool {
                if let source, event.source != source.lowercased() { return false }
                if let titleContains,
                   !event.title.localizedCaseInsensitiveContains(titleContains) { return false }
                if let urgencyAtMost, event.urgency > urgencyAtMost { return false }
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
    }

    var rules: [Rule]
    var quietHours: QuietHours?

    static let empty = RuleSet(rules: [], quietHours: nil)
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
    private enum CodingKeys: String, CodingKey { case match }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        match = try container.decodeIfPresent(Match.self, forKey: .match) ?? Match()
        // The same decoder, not a nested one: `delivery`/`digest` are the
        // rule's own keys.
        delivery = try Delivery(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(match, forKey: .match)
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
