import Foundation

/// Fetches GitHub issues involving the current user via the GitHub CLI (`gh`),
/// through the shared `GitHubCLI` subprocess helper. `gh search issues` returns
/// only issues (not PRs) by default.
struct IssueProvider {
    /// JSON fields requested from `gh search issues`.
    private static let jsonFields = "title,url,repository,updatedAt"

    /// Open issues authored by the current user, most recently updated first.
    func fetchAuthored(limit: Int = 100) async throws -> [IssueItem] {
        try await GitHubCLI.runJSON([
            "search", "issues",
            "--author=@me",
            "--state=open",
            "--sort", "updated",
            "--order", "desc",
            "--limit", String(limit),
            "--json", Self.jsonFields,
        ])
    }

    /// Open issues assigned to the current user, most recently updated first.
    func fetchAssigned(limit: Int = 100) async throws -> [IssueItem] {
        try await GitHubCLI.runJSON([
            "search", "issues",
            "--assignee=@me",
            "--state=open",
            "--sort", "updated",
            "--order", "desc",
            "--limit", String(limit),
            "--json", Self.jsonFields,
        ])
    }
}
