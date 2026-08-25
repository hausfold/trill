import Foundation

/// Pure decision function over (event, rules, clock, Focus). No I/O, no clock
/// reads of its own, no look at the system — everything injected, everything
/// unit-testable.
///
/// The Focus reading arrives the same way the clock does: as a value somebody
/// else read (`FocusReader`), already gated by the user's switch. This engine
/// never asks macOS anything and — the invariant that matters — never *writes*
/// a Focus. Turning one on or off is the desktop's dial and the user's click;
/// trill only notices.
struct PolicyEngine: Sendable {
    var ruleSet: RuleSet

    func decide(
        _ event: NotificationEvent,
        now: Date,
        focus: SystemFocus = .off,
        calendar: Calendar = .current
    ) -> DeliveryDecision {
        // First matching rule wins — including for *where* it draws: the
        // display is that same rule's, never a second walk of the list.
        for rule in ruleSet.rules where rule.match.matches(event) {
            switch rule.delivery {
            case .banner:
                return ambient(
                    .banner(rule.display ?? .primary),
                    for: event, now: now, focus: focus, calendar: calendar
                )
            case .inbox: return .inboxOnly
            case .digest(let name): return .digest(name)
            case .drop: return .drop
            }
        }
        return ambient(.banner(.primary), for: event, now: now, focus: focus, calendar: calendar)
    }

    /// The two signals that are about *the moment*, not about the event: a
    /// Focus macOS is in, and a window the user declared. Both only ever
    /// quieten something that was going to be drawn — neither can make a
    /// `digest` or an `inbox` rule louder, because a rule that said "quiet"
    /// said it about every hour of the day.
    ///
    /// **Critical is exempt from both.** A rule can still `drop` a critical
    /// event; an ambient signal never can. That was already quiet hours'
    /// promise and a Focus inherits it unchanged — there is one rule here,
    /// not two that have to be kept in step.
    private func ambient(
        _ decision: DeliveryDecision,
        for event: NotificationEvent,
        now: Date,
        focus: SystemFocus,
        calendar: Calendar
    ) -> DeliveryDecision {
        guard case .banner(let display) = decision, event.urgency < .critical
        else { return decision }

        var adjusted = decision

        if focus.isOn {
            switch (ruleSet.focus ?? .standard).behavior(for: event.kind) {
            case .banner:
                break
            case .inbox:
                adjusted = .inboxOnly
            case .ledge:
                // The ledge holds questions. Anything else configured to park
                // is filed instead — a fin nobody can answer is furniture on
                // the edge of the screen, and `BannerQueue.park` refuses it a
                // second time rather than trusting this one.
                adjusted = event.kind == .ask ? .ledge(display) : .inboxOnly
            }
        }

        // Quiet hours are the stricter of the two and go last, so they have
        // the final say over what a Focus decided. A user who wrote down
        // "22:00–07:00, nothing on this screen" meant the fin too: a question
        // parked at 3am is a question they see at 07:01 in the inbox, which
        // is where a night of held-back events already is.
        if let quiet = ruleSet.quietHours, quiet.contains(now, calendar: calendar),
           adjusted.isBanner || adjusted.isLedge {
            adjusted = .inboxOnly
        }

        return adjusted
    }
}
