import EventKit
import Foundation
import os.log

/// **Calendar.** The one source that doesn't wait to be told: EventKit runs
/// in-process, and macOS *pushes* — a meeting moved on your phone reaches this
/// provider as an `EKEventStoreChanged` note seconds later, with no polling
/// loop and no second daemon.
///
/// What it draws is one banner per occurrence, `leadTime` before it starts:
/// the title, "in 10m", and an Open pill that lands on the event in Calendar —
/// plus a Join pill when the invite carries a link trill recognizes as a
/// meeting. That is the whole feature; it is not a calendar client.
///
/// The house rules apply as they do to every provider:
///   - EventKit types stop at this file. Everything crossing out is a
///     `CalendarOccurrence`, and the decisions are `CalendarEventMapper`'s,
///     which is pure and tested headless;
///   - off by default, and the toggle is checked *before* anything asks macOS
///     for permission — trill never springs a Calendars prompt on a launch
///     nobody asked anything of;
///   - a refused or write-only grant is "off with a reason" in Settings, and
///     the rest of the app never notices.
struct CalendarProvider: NotificationProvider {
    let name = "calendar"
    let capabilities = ProviderCapabilities(canOpenSource: true, canDismissAtSource: false)

    /// Read from the config file's store rather than `AppSettings`: the
    /// supervisor calls this off the main actor, and the toggle's only job
    /// here is yes/no.
    private let enabled: @Sendable () -> Bool
    private let leadTime: @Sendable () -> TimeInterval

    static let log = Logger(subsystem: "com.hausfold.trill", category: "calendar")

    init(
        enabled: @escaping @Sendable () -> Bool = { ConfigFileStore.shared.current().calendarEnabled },
        leadTime: @escaping @Sendable () -> TimeInterval = {
            TimeInterval(ConfigFileStore.shared.current().calendarLeadMinutes * 60)
        }
    ) {
        self.enabled = enabled
        self.leadTime = leadTime
    }

    // MARK: - Permission

    /// macOS's answer right now, without asking it anything. Settings reads
    /// this to decide whether the row needs a Grant button.
    static var authorization: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    /// Ask for read access, presenting Apple's sheet if it hasn't been
    /// answered yet. Called when the switch goes on — not from `probe()` —
    /// so the prompt arrives on the click that asked for it rather than
    /// whenever the supervisor's backoff next comes round.
    @discardableResult
    static func requestAccess() async -> Bool {
        let store = EKEventStore()
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            log.info("calendar access request failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Why this source isn't running, in the words Settings shows. Nil when
    /// macOS has granted read access.
    static func accessComplaint(for status: EKAuthorizationStatus) -> String? {
        switch status {
        case .fullAccess:
            return nil
        case .notDetermined:
            return "trill hasn’t asked macOS for your calendar yet."
        case .writeOnly:
            return "macOS gave trill write-only calendar access — it needs to *read* your calendar to know what’s next. Change it in System Settings › Privacy & Security › Calendars."
        case .denied:
            return "Calendar access is off for trill. Turn it on in System Settings › Privacy & Security › Calendars."
        case .restricted:
            return "Calendar access is restricted on this Mac — a profile or Screen Time is holding it."
        @unknown default:
            return "Calendar access is in a state this build of trill doesn’t recognize."
        }
    }

    func probe() async -> ProviderHealth {
        guard enabled() else { return .unavailable(reason: "switched off in Settings") }
        if let complaint = Self.accessComplaint(for: Self.authorization) {
            return .unavailable(reason: complaint)
        }
        return .ready
    }

    func events() async -> AsyncStream<NotificationEvent> {
        AsyncStream { continuation in
            guard enabled(), Self.accessComplaint(for: Self.authorization) == nil else {
                continuation.finish()
                return
            }
            let watcher = CalendarWatcher(
                enabled: enabled,
                leadTime: leadTime,
                yield: { continuation.yield($0) },
                finish: { continuation.finish() }
            )
            watcher.start()
            continuation.onTermination = { _ in watcher.stop() }
        }
    }
}

/// The moving parts: one `EKEventStore`, one schedule of what's coming, and
/// one timer deciding when the next banner is owed.
///
/// Serialized on a single queue the way `RulesWatcher` and `ConfigFileStore`
/// are, because the same three callers arrive at once — EventKit's change
/// notification on whatever thread it likes, the tick timer, and the stream's
/// termination handler.
final class CalendarWatcher: @unchecked Sendable {
    /// How far ahead the schedule looks. A day, because a re-query is cheap
    /// and a longer horizon buys nothing: every change inside it arrives as
    /// a push anyway.
    static let horizon: TimeInterval = 24 * 3600
    /// How often the schedule is rebuilt from EventKit regardless of pushes.
    /// A belt to the notification's braces — a store that goes quiet after a
    /// sync error shouldn't cost you a meeting.
    static let refreshInterval: TimeInterval = 10 * 60
    /// Tick granularity. Invisible against a ten-minute lead, and cheap: a
    /// tick that finds nothing due compares two dates.
    static let tick: TimeInterval = 5
    /// A reminder that came due while the Mac slept still banners, as long as
    /// the meeting itself hasn't started by more than this. Past it the
    /// occurrence is marked seen and stays silent — trill doesn't tell you
    /// about a meeting you're already in.
    static let grace: TimeInterval = 60
    /// How long a fired occurrence is remembered, so a re-query can't banner
    /// the same meeting twice.
    static let memory: TimeInterval = 2 * 3600

    private let queue = DispatchQueue(label: "com.hausfold.trill.calendar")
    private let enabled: @Sendable () -> Bool
    private let leadTime: @Sendable () -> TimeInterval
    private let yield: @Sendable (NotificationEvent) -> Void
    private let finish: @Sendable () -> Void

    private var store: EKEventStore?
    private var observer: NSObjectProtocol?
    private var timer: DispatchSourceTimer?
    /// What's coming, sorted by start. Rebuilt whole; never patched.
    private var schedule: [CalendarOccurrence] = []
    /// Occurrence id → its start, for pruning. The provider's own dedupe:
    /// `EventRepository` has one too, but its window is shared with every
    /// other source and a busy day could age an occurrence out of it.
    private var fired: [String: Date] = [:]
    private var lastRefresh: Date = .distantPast
    private var lastLead: TimeInterval = -1

    init(
        enabled: @escaping @Sendable () -> Bool,
        leadTime: @escaping @Sendable () -> TimeInterval,
        yield: @escaping @Sendable (NotificationEvent) -> Void,
        finish: @escaping @Sendable () -> Void
    ) {
        self.enabled = enabled
        self.leadTime = leadTime
        self.yield = yield
        self.finish = finish
    }

    func start() {
        queue.async { [self] in
            guard store == nil else { return }
            let store = EKEventStore()
            self.store = store
            // Scoped to this store object: EventKit posts it for any change
            // that reached this process, which is exactly the push that makes
            // polling unnecessary.
            observer = NotificationCenter.default.addObserver(
                forName: .EKEventStoreChanged, object: store, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.refresh() }
            }
            refresh()
            arm()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            if let observer {
                NotificationCenter.default.removeObserver(observer)
                self.observer = nil
            }
            store = nil
            schedule = []
        }
    }

    private func arm() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        // A *wall* deadline, not a monotonic one: the machine sleeps through
        // most of any given lead time, and a timer measured in uptime would
        // wake up believing no time had passed.
        source.schedule(
            wallDeadline: .now() + Self.tick,
            repeating: Self.tick,
            leeway: .seconds(1)
        )
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    private func tick() {
        guard enabled() else {
            CalendarProvider.log.info("calendar source switched off — stopping")
            stop()
            finish()
            return
        }
        let now = Date()
        let lead = leadTime()
        // A changed lead moves every pending banner, so the schedule is worth
        // rebuilding — and `fired` is deliberately kept: shortening the lead
        // must not re-announce what already went out.
        if lead != lastLead || now.timeIntervalSince(lastRefresh) >= Self.refreshInterval {
            lastLead = lead
            refresh(now: now)
        }
        deliverDue(now: now, leadTime: lead)
    }

    /// Rebuild the schedule from EventKit. Whole, never patched: a deletion,
    /// a decline and a moved start are all just "the answer is different now",
    /// and re-asking is both simpler and the only version that can't drift.
    private func refresh(now: Date = Date()) {
        guard let store else { return }
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(Self.horizon), calendars: nil
        )
        schedule = store.events(matching: predicate)
            .compactMap(Self.occurrence(from:))
            .filter(CalendarEventMapper.remindable)
            .sorted { $0.start < $1.start }
        lastRefresh = now
        fired = fired.filter { $0.value > now.addingTimeInterval(-Self.memory) }
        CalendarProvider.log.debug("calendar schedule: \(self.schedule.count, privacy: .public) upcoming")
    }

    private func deliverDue(now: Date, leadTime lead: TimeInterval) {
        for occurrence in schedule {
            guard fired[occurrence.identifier] == nil else { continue }
            // Sorted by start, and the lead is uniform, so the first
            // not-yet-due occurrence ends the day's work.
            guard CalendarEventMapper.isDue(occurrence, leadTime: lead, now: now) else { break }
            fired[occurrence.identifier] = occurrence.start
            guard occurrence.start > now.addingTimeInterval(-Self.grace) else { continue }
            yield(CalendarEventMapper.event(for: occurrence, now: now))
        }
    }

    /// The EventKit boundary, and the only place an `EKEvent` is touched.
    static func occurrence(from event: EKEvent) -> CalendarOccurrence? {
        guard let start = event.startDate else { return nil }
        // An item identifier is shared by every instance of a recurring
        // event, so the start is part of the name. Whole seconds, so a
        // re-query can't produce a hair's-width different id for the same
        // occurrence.
        let identifier = "\(event.calendarItemIdentifier)|\(Int(start.timeIntervalSince1970))"
        let declined = event.attendees?
            .first { $0.isCurrentUser }?
            .participantStatus == .declined
        return CalendarOccurrence(
            identifier: identifier,
            externalIdentifier: event.calendarItemExternalIdentifier,
            title: event.title ?? "",
            start: start,
            isAllDay: event.isAllDay,
            isCancelled: event.status == .canceled,
            isDeclined: declined,
            calendarTitle: event.calendar?.title ?? "",
            location: event.location,
            notes: event.notes,
            url: event.url
        )
    }
}
