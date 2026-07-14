import Foundation

/// A pull request authored by the current user, as returned by `gh search prs`.
struct PullRequestItem: Identifiable, Sendable, Codable, Equatable {
    struct Repository: Sendable, Codable, Equatable {
        var nameWithOwner: String
    }

    var title: String
    var url: String
    var repository: Repository
    /// "open", "closed" (closed without merging), or "merged".
    var state: String
    var updatedAt: Date
    var closedAt: Date?
    var isDraft: Bool?

    /// Stable identity: the PR URL is unique across all repositories.
    var id: String { url }

    var isOpen: Bool { state == "open" }
    var isDraftPR: Bool { isDraft == true }
}
