import Foundation

/// Pure decision function over (event, rules, clock). No I/O, no clock reads
/// of its own — everything injected, everything unit-testable.
struct PolicyEngine: Sendable {
    var ruleSet: RuleSet

    func decide(_ event: NotificationEvent, now: Date, calendar: Calendar = .current) -> DeliveryDecision {
        // First matching rule wins.
        for rule in ruleSet.rules where rule.match.matches(event) {
            switch rule.delivery {
            case .banner: return quietAdjusted(.banner, for: event, now: now, calendar: calendar)
            case .inbox: return .inboxOnly
            case .digest(let name): return .digest(name)
            case .drop: return .drop
            }
        }
        return quietAdjusted(.banner, for: event, now: now, calendar: calendar)
    }

    /// Quiet hours demote banners to inbox-only. Critical events are the one
    /// exception: a rule can still `drop` them, but silence never can.
    private func quietAdjusted(
        _ decision: DeliveryDecision,
        for event: NotificationEvent,
        now: Date,
        calendar: Calendar
    ) -> DeliveryDecision {
        guard decision == .banner,
              let quiet = ruleSet.quietHours,
              event.urgency < .critical
        else { return decision }

        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        return quiet.contains(minuteOfDay: minute) ? .inboxOnly : decision
    }
}
