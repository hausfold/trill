import Foundation
import os.log

/// The single funnel between providers and everything else. Owns dedupe,
/// normalization, persistence, and fan-out; supervises each provider in its
/// own task so one misbehaving source can never stall another — or the
/// compositor.
actor EventRepository {
    private let policy: () -> PolicyEngine
    private let database: AppDatabase?
    private var seenIDs: OrderedIDWindow

    private var subscribers: [UUID: AsyncStream<DeliveredEvent>.Continuation] = [:]
    private var providerTasks: [String: Task<Void, Never>] = [:]
    private(set) var providerHealth: [String: ProviderHealth] = [:]

    // Content stays out of logs — ids and sources only.
    private static let log = Logger(subsystem: "com.hausfold.trill", category: "repository")

    struct DeliveredEvent: Sendable {
        let event: NotificationEvent
        let decision: DeliveryDecision
    }

    init(policy: @escaping @Sendable () -> PolicyEngine, database: AppDatabase?) {
        self.policy = policy
        self.database = database
        self.seenIDs = OrderedIDWindow(capacity: 2048)
    }

    // MARK: - Provider supervision

    /// Runs a provider's lifecycle: probe → stream → (on finish) backoff and
    /// re-probe. A provider that keeps failing keeps its `unavailable`
    /// reason visible in settings and costs nothing but a sleeping task.
    func supervise(_ provider: some NotificationProvider) {
        guard providerTasks[provider.name] == nil else { return }
        providerTasks[provider.name] = Task { [weak self] in
            var backoff: Duration = .seconds(1)
            while !Task.isCancelled {
                let health = await provider.probe()
                await self?.recordHealth(health, for: provider.name)

                if case .ready = health {
                    backoff = .seconds(1)
                    for await event in await provider.events() {
                        await self?.ingest(event, from: provider.name)
                    }
                    // Stream finished: provider hit a wall. Fall through to
                    // backoff + re-probe.
                }
                try? await Task.sleep(for: backoff)
                backoff = min(backoff * 2, .seconds(60))
            }
        }
    }

    func shutdown() {
        providerTasks.values.forEach { $0.cancel() }
        providerTasks.removeAll()
        subscribers.values.forEach { $0.finish() }
        subscribers.removeAll()
    }

    private func recordHealth(_ health: ProviderHealth, for name: String) {
        providerHealth[name] = health
        if case .unavailable(let reason) = health {
            Self.log.info("provider \(name, privacy: .public) unavailable: \(reason, privacy: .public)")
        }
    }

    // MARK: - Ingest

    func ingest(_ raw: NotificationEvent, from providerName: String) {
        let event = raw.normalized()

        guard seenIDs.insert(event.id) else {
            Self.log.debug("dropped duplicate \(event.id, privacy: .public)")
            return
        }

        let decision = policy().decide(event, now: .now)
        if decision == .drop { return }

        database?.insert(event, decision: decision)
        Self.log.debug("ingested \(event.id, privacy: .public) from \(providerName, privacy: .public)")

        let delivered = DeliveredEvent(event: event, decision: decision)
        for continuation in subscribers.values {
            continuation.yield(delivered)
        }
    }

    // MARK: - Fan-out

    func deliveries() -> AsyncStream<DeliveredEvent> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { _ in
                Task { [weak self] in await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }
}

/// Fixed-size recency window for dedupe: O(1) membership, bounded memory,
/// oldest ids age out first.
struct OrderedIDWindow: Sendable {
    private var members: Set<String> = []
    private var order: [String] = []
    private var head = 0
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    /// True if newly inserted, false if already present.
    mutating func insert(_ id: String) -> Bool {
        guard !members.contains(id) else { return false }
        if order.count < capacity {
            order.append(id)
        } else {
            members.remove(order[head])
            order[head] = id
            head = (head + 1) % capacity
        }
        members.insert(id)
        return true
    }
}
