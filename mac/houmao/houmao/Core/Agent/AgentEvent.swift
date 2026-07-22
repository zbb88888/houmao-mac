import Foundation

/// A proactively-surfaced item detected by a `Watcher` — something the user
/// probably wants to act on (e.g. an issue newly assigned to them, a PR
/// requesting their review).
///
/// The proactive agent only ever *surfaces* these; acting on one is always an
/// explicit, user-initiated step via `suggestedCommand` (which reuses the
/// existing `/pr` / `/issue` chat commands). No consequential action is ever
/// taken automatically.
struct AgentEvent: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        /// A GitHub issue assigned to the current user.
        case assignedIssue
        /// A GitHub pull request requesting the current user's review.
        case reviewRequestedPR
        /// A cluster of new, non-routine mail detected by the mail watcher.
        case newMailCluster
    }

    /// Stable identity: the GitHub URL is globally unique, so the same item is
    /// never surfaced (or notified) twice.
    var id: String
    var kind: Kind
    var title: String
    /// Secondary line, e.g. "owner/repo".
    var subtitle: String
    var url: String
    /// When the agent first detected this item.
    var detectedAt: Date
    /// A chat command the user can trigger with one click (e.g. "/pr <url>"),
    /// reusing the shared `MainViewModel.handleToolCommand` dispatch.
    var suggestedCommand: String
}
