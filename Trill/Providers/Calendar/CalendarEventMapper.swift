import Foundation

/// One occurrence of one calendar event, flattened to the shape trill needs.
///
/// EventKit's own types stop at `CalendarProvider`, the way usernoted's stop
/// at `SystemMirrorProvider` — this is what crosses that line. It is also what
/// makes the interesting half of this source a pure function: *should this
/// banner, when, and what does it say* is decided here, over plain values,
/// with no `EKEventStore` anywhere near a test.
struct CalendarOccurrence: Equatable, Sendable {
    /// Stable per-*occurrence* name. An EventKit item identifier alone is
    /// shared by every instance of a recurring event, so the start time is
    /// part of it. It doubles as trill's dedupe id, which is why a meeting
    /// that gets *moved* becomes a different occurrence and earns a fresh
    /// reminder, instead of being silently swallowed as a duplicate.
    var identifier: String
    /// EventKit's *external* identifier — the one Calendar's `ical://` URL
    /// takes. Some stores don't publish one; the Open pill degrades to
    /// activating Calendar when they don't.
    var externalIdentifier: String?
    var title: String
    var start: Date
    var isAllDay: Bool
    /// The organizer withdrew it. Distinct from declined: this one is gone
    /// for everybody.
    var isCancelled: Bool
    /// The user's own reply was "no". A meeting you said no to is not a
    /// meeting trill nags you about.
    var isDeclined: Bool
    var calendarTitle: String
    var location: String?
    var notes: String?
    /// The event's own URL field — where Google Calendar and Zoom put the
    /// conference link when the invite came in cleanly.
    var url: URL?
}

/// The pure half of the calendar source: which occurrences deserve a banner,
/// when to draw it, and what it says.
enum CalendarEventMapper {
    /// The slug `rules.json` matches on — `{"match": {"source": "calendar"}}`.
    static let source = "calendar"

    /// Apple's Calendar, named once so the Open pill's fallback and
    /// `ActionRouter`'s can't drift apart.
    static let calendarBundleID = "com.apple.iCal"

    /// An occurrence that has already started never banners retroactively —
    /// but a reminder whose moment passed while the Mac was asleep still
    /// does, for as long as the meeting hasn't begun. This is that line.
    static func remindable(_ occurrence: CalendarOccurrence) -> Bool {
        !occurrence.isAllDay && !occurrence.isCancelled && !occurrence.isDeclined
    }

    /// When this occurrence's banner is due.
    static func fireDate(for occurrence: CalendarOccurrence, leadTime: TimeInterval) -> Date {
        occurrence.start.addingTimeInterval(-leadTime)
    }

    /// Is it time? Answered against the fire date rather than "is `now`
    /// within `leadTime`", so a reminder missed across sleep is still owed —
    /// the caller decides whether the meeting has since started.
    static func isDue(_ occurrence: CalendarOccurrence, leadTime: TimeInterval, now: Date) -> Bool {
        fireDate(for: occurrence, leadTime: leadTime) <= now
    }

    // MARK: - Words

    /// "in 10m" — the whole point of the banner, and the reason it is
    /// computed from `now` rather than printed from the configured lead: a
    /// timer that fired late, or a Mac that woke up late, should say what is
    /// true, not what was scheduled.
    static func leadPhrase(start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 30 else { return "starting now" }
        let minutes = Int((seconds / 60).rounded())
        guard minutes >= 60 else { return "in \(minutes)m" }
        let (hours, rest) = (minutes / 60, minutes % 60)
        return rest == 0 ? "in \(hours)h" : "in \(hours)h \(rest)m"
    }

    /// "in 10m · 2:30 PM". The clock time is there because the countdown
    /// alone is unanchored: a banner you glance at 40 seconds later should
    /// still tell you when the thing is.
    static func subtitle(
        for occurrence: CalendarOccurrence,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let clock = occurrence.start.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
        )
        return "\(leadPhrase(start: occurrence.start, now: now)) · \(clock)"
    }

    // MARK: - The Join pill

    /// Hosts trill is willing to call a meeting. A whitelist, because "Join"
    /// has to mean *join*: the first `https://` in someone's meeting notes is
    /// as often a spec, a doc or a ticket, and a pill that opens one of those
    /// is a lie in a button. No recognized host, no Join pill.
    ///
    /// Matched on the registrable suffix (`us02web.zoom.us` counts,
    /// `notzoom.us` does not), so a provider's per-tenant subdomains work
    /// without listing them.
    static let conferencingHosts = [
        "meet.google.com",
        "zoom.us",
        "zoomgov.com",
        "teams.microsoft.com",
        "teams.live.com",
        "webex.com",
        "whereby.com",
        "meet.jit.si",
        "chime.aws",
        "bluejeans.com",
        "gotomeeting.com",
        "gotomeet.me",
        "meet.goto.com",
        "around.co",
    ]

    static func isConferencing(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased()
        else { return false }
        return conferencingHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The meeting link, if there is one: the event's own `url` field first
    /// (where a clean invite puts it), then the location, then the notes.
    /// Every candidate still has to clear `isConferencing`.
    static func meetingURL(in occurrence: CalendarOccurrence) -> URL? {
        if let url = occurrence.url, isConferencing(url) { return url }
        for text in [occurrence.location, occurrence.notes].compactMap({ $0 }) {
            if let found = links(in: text).first(where: isConferencing) { return found }
        }
        return nil
    }

    /// Links in free text. `NSDataDetector` rather than a regex because
    /// invite bodies wrap, bracket and trail-punctuate URLs in every way a
    /// hand-rolled pattern gets wrong.
    private static func links(in text: String) -> [URL] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return detector.matches(in: text, range: range).compactMap(\.url)
    }

    // MARK: - The event

    /// The banner itself.
    ///
    /// `kind` is `.note`, deliberately, and not `.ask`: an `ask` that times
    /// out parks on the ledge until something answers it, and nothing ever
    /// answers "your 2pm is in 10 minutes". It would sit there at 5pm still
    /// claiming ten minutes. A meeting reminder is a thing you were told, so
    /// it is a note.
    static func event(
        for occurrence: CalendarOccurrence,
        now: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> NotificationEvent {
        let joinURL = meetingURL(in: occurrence)
        let title = occurrence.title.trimmingCharacters(in: .whitespacesAndNewlines)

        // Open first, so the *card* click — which runs only the first action
        // — lands in Calendar rather than in a call. Joining a meeting is a
        // thing you should have to mean.
        var actions: [NotificationEvent.Action] = [openAction(for: occurrence)]
        if let joinURL {
            actions.append(.init(id: "join", label: "Join", kind: .openURL, target: joinURL.absoluteString))
        }

        var metadata = ["calendar": occurrence.calendarTitle]
        metadata["starts"] = ISO8601DateFormatter().string(from: occurrence.start)

        // The location, unless the location *is* the link the Join pill
        // already carries — a banner that says "Zoom" twice says it once too
        // often.
        let location = occurrence.location?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = location.flatMap { text -> String? in
            guard !text.isEmpty else { return nil }
            if let joinURL, text == joinURL.absoluteString { return nil }
            return text
        }
        if let location, !location.isEmpty { metadata["location"] = location }

        return NotificationEvent(
            id: "cal:\(occurrence.identifier)",
            source: source,
            timestamp: now,
            title: title.isEmpty ? "Untitled event" : title,
            subtitle: subtitle(for: occurrence, now: now, locale: locale, timeZone: timeZone),
            body: body,
            symbol: joinURL == nil ? "calendar" : "video.fill",
            kind: .note,
            actions: actions,
            metadata: metadata
        ).normalized()
    }

    /// Open the occurrence where the store publishes an external identifier;
    /// otherwise open Calendar. Never nothing: the pill is drawn either way,
    /// so it has to do something either way.
    private static func openAction(for occurrence: CalendarOccurrence) -> NotificationEvent.Action {
        if let external = occurrence.externalIdentifier,
           NotificationEvent.Action.namesCalendarEvent(external) {
            return .init(id: "open", label: "Open", kind: .openEvent, target: external)
        }
        return .init(id: "open", label: "Open", kind: .openApp, target: calendarBundleID)
    }
}
