import Foundation

/// One row of Apple's `usernoted` store, flattened to the shape trill needs.
///
/// usernoted's own vocabulary stops here. Its keys are four letters long
/// because a daemon that never expected a reader chose them (`req`, `titl`,
/// `durl`, `thre`), its body is sometimes a string and sometimes a
/// localization triple, and its dates count from 2001 — none of that may
/// appear anywhere else in the app, the same way EventKit's types stop at
/// `CalendarOccurrence`. This is what crosses that line.
struct UsernotedRecord: Equatable, Sendable {
    /// `record.rec_id` — monotonic, and therefore trill's high-water mark.
    var recordID: Int64
    /// `record.uuid`, when it decodes. The stable half of the event id: the
    /// same notification read twice across a restart must not banner twice.
    var uuid: UUID?
    /// Canonical-case bundle id (`com.apple.MobileSMS`). The `app` table
    /// lowercases; the blob doesn't, and the blob is the better name to show.
    var bundleID: String
    var deliveredAt: Date
    /// `record.style`: 1 when macOS drew a banner or alert of its own, 0 when
    /// it drew nothing. Measured, not documented — see ARCHITECTURE.md. It is
    /// carried rather than acted on: whether Apple already showed this is the
    /// user's business (that is what the Silence Native Banners helper is
    /// for), never a reason for trill to swallow the event.
    var nativeStyle: Int
    var title: String?
    var subtitle: String?
    var body: String?
    var threadID: String?
    var category: String?
    /// `req.unct` — `UNNotificationContentTypeMessagingDirect` and friends.
    /// The only field that says *what kind of thing this is* without trill
    /// keeping a list of which apps are chat apps.
    var contentType: String?
    /// `req.durl` — where the posting app wants a click to land
    /// (`messages://open?…`). Often absent, and never one of the schemes
    /// trill hands to the workspace, so it stays metadata rather than
    /// becoming an action: the Open pill activates the app instead.
    var destinationURL: String?

    /// Build a record from one row. Pure over already-decoded values, so the
    /// interesting half — which fields survive, and what to do when they
    /// don't — is testable with no database and no plist on disk.
    ///
    /// Returns nil for a row with nothing to draw: no title and no body is
    /// not a notification, it is a badge update.
    init?(recordID: Int64, uuid: UUID?, style: Int, deliveredDate: Double?, plist: [String: Any]) {
        let request = plist["req"] as? [String: Any] ?? [:]

        guard let bundleID = (plist["app"] as? String).flatMap(Self.nonEmpty) else { return nil }

        let title = (request["titl"] as? String).flatMap(Self.nonEmpty)
        let body = Self.text(request["body"])
        guard title != nil || body != nil else { return nil }

        // The blob's own `date` is what usernoted recorded at delivery and
        // the column is the same instant, so either will do: prefer the
        // column, fall back to the blob, and date a row missing both *now*
        // rather than at the turn of 2001.
        let absolute = deliveredDate ?? plist["date"] as? Double

        self.recordID = recordID
        self.uuid = uuid
        self.bundleID = bundleID
        self.deliveredAt = absolute.map { Date(timeIntervalSinceReferenceDate: $0) } ?? .now
        self.nativeStyle = style
        self.title = title
        self.subtitle = (request["subt"] as? String).flatMap(Self.nonEmpty)
        self.body = body
        self.threadID = (request["thre"] as? String).flatMap(Self.nonEmpty)
        self.category = (request["cate"] as? String).flatMap(Self.nonEmpty)
        self.contentType = (request["unct"] as? String).flatMap(Self.nonEmpty)
        self.destinationURL = (request["durl"] as? String).flatMap(Self.nonEmpty)
    }

    /// `req.body` is a `String` for most senders and a *localization triple*
    /// for some of Apple's own — `[key, "the resolved sentence", [args]]`,
    /// where element 1 is the only part a human wrote. Measured on Find My.
    /// Anything else in that position is not a sentence, so it is refused
    /// rather than stringified into `["a", "b"]` on someone's screen.
    static func text(_ value: Any?) -> String? {
        if let string = value as? String { return nonEmpty(string) }
        if let array = value as? [Any], array.count >= 2 {
            return (array[1] as? String).flatMap(nonEmpty)
        }
        return nil
    }

    private static func nonEmpty(_ string: String) -> String? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
