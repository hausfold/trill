import Foundation

/// What a provider can actually do, advertised up front (the family's
/// capability pattern). Surfaces render only what the source can honor — no dead
/// buttons, no pretending.
struct ProviderCapabilities: Sendable, Equatable {
    /// Events from this provider can be traced back to a launchable app.
    var canOpenSource: Bool = false
    /// Dismissing in trill can dismiss at the source too.
    var canDismissAtSource: Bool = false
    /// Provider reads undocumented system state; may vanish on any macOS
    /// update, and must degrade to "off", never to "broken".
    var experimental: Bool = false
}

/// A source of notification events. Providers are supervised, isolated, and
/// replaceable: each runs in its own task, its failures are its own, and the
/// compositor never blocks on any of them.
protocol NotificationProvider: Sendable {
    var name: String { get }
    var capabilities: ProviderCapabilities { get }

    /// Probe the environment (permissions, sockets, schemas) and report
    /// whether this provider can run right now. Called before `events()`
    /// and re-called on wake/settings changes — a failed probe disables the
    /// provider without touching the rest of the app.
    func probe() async -> ProviderHealth

    /// Long-lived event stream. Finishing the stream signals the supervisor
    /// to re-probe and restart with backoff; throwing is not part of the
    /// contract — a provider that can't continue finishes instead.
    func events() async -> AsyncStream<NotificationEvent>
}

enum ProviderHealth: Sendable, Equatable {
    case ready
    /// Provider cannot run and says why (missing permission, schema drift).
    /// The reason is surfaced in settings; the app carries on without it.
    case unavailable(reason: String)
}
