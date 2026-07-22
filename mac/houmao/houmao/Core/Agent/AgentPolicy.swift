import Foundation

/// Deterministic guardrails around the probabilistic/agentic loop. The agent may
/// poll and surface suggestions freely, but *when* it does is bounded here: a
/// master enable switch, a poll cadence, and a quiet-hours window. Consequential
/// actions are never taken here — the agent only ever notifies + suggests (see
/// `AgentEvent.suggestedCommand`).
struct AgentPolicy: Equatable, Sendable {
    /// Master switch for the whole background loop. Defaults off — the user must
    /// opt in.
    var isEnabled: Bool
    /// Poll cadence in minutes.
    var intervalMinutes: Int
    /// Quiet-hours window (local wall-clock hours, 0–23). When `start == end`,
    /// quiet hours are disabled. The window may wrap past midnight (e.g. 22 → 8).
    var quietStartHour: Int
    var quietEndHour: Int
    /// Max items surfaced (notified) per poll, so a first run over a large
    /// backlog doesn't spam.
    var maxPerPoll: Int

    static let `default` = AgentPolicy(
        isEnabled: false,
        intervalMinutes: 15,
        quietStartHour: 0,
        quietEndHour: 0,
        maxPerPoll: 5
    )

    /// Whether polling is allowed right now: enabled and outside quiet hours.
    func allowsPoll(at date: Date, calendar: Calendar = .current) -> Bool {
        isEnabled && !isQuiet(at: date, calendar: calendar)
    }

    /// True if `date`'s local hour falls within the quiet-hours window.
    func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietStartHour != quietEndHour else { return false }
        let hour = calendar.component(.hour, from: date)
        if quietStartHour < quietEndHour {
            return hour >= quietStartHour && hour < quietEndHour
        } else {
            // Wraps past midnight, e.g. 22 → 8.
            return hour >= quietStartHour || hour < quietEndHour
        }
    }
}
