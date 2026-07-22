import Foundation

/// The proactive agent's (deterministic) decision layer.
///
/// Given the freshly-polled events and the set of ids already seen, return only
/// the genuinely new ones — those worth a notification. De-duplicates by id so
/// the same item is surfaced exactly once, even if it appears twice in a single
/// poll. MVP keeps this purely rule-based; tree search / LLM ranking are future
/// work (see docs/proactive-agency.md §1).
enum AgentDiff {
    /// New events in `current` not present in `seen`, first occurrence wins.
    static func newEvents(current: [AgentEvent], seen: Set<String>) -> [AgentEvent] {
        var result: [AgentEvent] = []
        var localSeen = seen
        for event in current where !localSeen.contains(event.id) {
            localSeen.insert(event.id)
            result.append(event)
        }
        return result
    }
}
