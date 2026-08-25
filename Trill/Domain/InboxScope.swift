import Foundation

/// What one inbox window is showing.
///
/// It round-trips through a string because it is also the payload of an
/// `open_inbox` action: a digest card carries its own scope, so the click that
/// opens the window says *which* events it was about without the compositor
/// keeping a side table of cards it has drawn.
enum InboxScope: Equatable, Sendable {
    /// Everything the policy engine let through — the plain window.
    case all
    /// `trill inbox --asks`: only `ask` events, the kind the ledge parks.
    case asks
    /// Exactly what one digest card counted: the digest's name, and the
    /// instant its window opened.
    case digest(name: String, since: Date)
    /// Everything stored since an instant — what a catch-up card's click
    /// opens, scoped to the absence it counted.
    case since(Date)

    /// Longest name an action target may carry. A digest name comes from the
    /// user's own `rules.json`, so this is a sanity bound rather than a
    /// defence — but the target also arrives over the socket inside a
    /// hand-authored event, and an unbounded one has no business here.
    static let nameLimit = 100

    var actionTarget: String {
        switch self {
        case .all: "all"
        case .asks: "asks"
        case .digest(let name, let since):
            "digest:\(name)@\(Int(since.timeIntervalSince1970))"
        case .since(let instant):
            "since:\(Int(instant.timeIntervalSince1970))"
        }
    }

    /// Does this window open filtered to what trill never showed you?
    ///
    /// Only the catch-up scope, and only because its card counted exactly
    /// that: a click that landed on a longer list than the number it came
    /// from would make the number look wrong. It is the *initial* state of a
    /// toggle the user still owns, not a filter baked into the query —
    /// turning it off widens to everything the window covers, which is the
    /// natural next question.
    var opensUnreadOnly: Bool {
        if case .since = self { return true }
        return false
    }

    /// Parse an action target back into a scope. `nil` — an `open_inbox`
    /// action that names no scope — is the plain window, not a failure; a
    /// target trill can't read *is* a failure, and returning nil here is what
    /// keeps `isPerformable` from drawing that action as a pressable button.
    init?(actionTarget: String?) {
        guard let actionTarget else {
            self = .all
            return
        }
        switch actionTarget {
        case "", "all":
            self = .all
        case "asks":
            self = .asks
        case let target where target.hasPrefix("since:"):
            guard let seconds = TimeInterval(target.dropFirst("since:".count)) else { return nil }
            self = .since(Date(timeIntervalSince1970: seconds))
        default:
            // `digest:<name>@<epoch seconds>`. Split at the *last* `@` so a
            // name containing one survives the round trip.
            guard actionTarget.hasPrefix("digest:") else { return nil }
            let rest = actionTarget.dropFirst("digest:".count)
            guard let at = rest.lastIndex(of: "@") else { return nil }
            let name = String(rest[..<at])
            guard !name.isEmpty, name.count <= Self.nameLimit,
                  let seconds = TimeInterval(rest[rest.index(after: at)...])
            else { return nil }
            self = .digest(name: name, since: Date(timeIntervalSince1970: seconds))
        }
    }
}
