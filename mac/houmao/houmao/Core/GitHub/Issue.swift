import Foundation

/// A GitHub issue involving the current user, as returned by `gh search issues`.
struct IssueItem: Identifiable, Sendable, Codable, Equatable {
    struct Repository: Sendable, Codable, Equatable {
        var nameWithOwner: String
    }

    var title: String
    var url: String
    var repository: Repository
    var updatedAt: Date

    /// Stable identity: the issue URL is unique across all repositories.
    var id: String { url }
}
