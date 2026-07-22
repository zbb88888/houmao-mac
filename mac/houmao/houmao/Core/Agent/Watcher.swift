import Foundation

/// A source the proactive agent polls to detect items worth surfacing.
///
/// Pure sensing: `poll()` returns the *current* set of relevant items; deciding
/// which of those are genuinely new (and thus worth a notification) is
/// `AgentDiff`'s job, not the watcher's. New sources (Gmail, to-dos, goals) plug
/// in by conforming here without touching the daemon.
protocol Watcher: Sendable {
    /// Stable identifier, used to enable/disable the watcher and for logging.
    var id: String { get }
    /// Sense the source and return all currently-relevant items.
    func poll() async throws -> [AgentEvent]
}
