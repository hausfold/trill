import Foundation

/// Pure decision function over (event, rules, clock). No I/O, no clock reads
/// of its own — everything injected, everything unit-testable.
struct PolicyEngine: Sendable {
    var ruleSet: RuleSet

    func decide(_ event: NotificationEvent, now: Date, calendar: Calendar = .current) -> DeliveryDecision {
        // First matching rule wins — including for *where* it draws: the
        // display is that same rule's, never a second walk of the list.
        for rule in ruleSet.rules where rule.match.matches(event) {
            switch rule.delivery {
            case .banner:
                return quietAdjusted(
                    .banner(rule.display ?? .primary), for: event, now: now, calendar: calendar
                )
            case .inbox: return .inboxOnly
            case .digest(let name): return .digest(name)
            case .drop: return .drop
            }
        }
        return quietAdjusted(.banner(.primary), for: event, now: now, calendar: calendar)
    }

    /// Quiet hours demote banners to inbox-only. Critical events are the one
    /// exception: a rule can still `drop` them, but silence never can.
    private func quietAdjusted(
        _ decision: DeliveryDecision,
        for event: NotificationEvent,
        now: Date,
        calendar: Calendar
    ) -> DeliveryDecision {
        guard case .banner = decision,
              let quiet = ruleSet.quietHours,
              event.urgency < .critical
        else { return decision }

        return quiet.contains(now, calendar: calendar) ? .inboxOnly : decision
    }
}
