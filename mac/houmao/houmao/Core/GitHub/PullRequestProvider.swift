import Foundation

/// Fetches the current user's pull requests via the GitHub CLI (`gh`), through
/// the shared `GitHubCLI` subprocess helper.
struct PullRequestProvider {
    /// JSON fields requested from `gh search prs`.
    private static let jsonFields = "title,url,repository,state,updatedAt,closedAt,isDraft"

    /// Open PRs authored by the current user, across all repositories, most
    /// recently updated first.
    func fetchOpen(limit: Int = 100) async throws -> [PullRequestItem] {
        try await GitHubCLI.runJSON([
            "search", "prs",
            "--author=@me",
            "--state=open",
            "--sort", "updated",
            "--order", "desc",
            "--limit", String(limit),
            "--json", Self.jsonFields,
        ])
    }

    /// Closed / merged PRs authored by the current user, closed on or after
    /// `since`, most recently updated first.
    func fetchClosed(since: Date, limit: Int = 100) async throws -> [PullRequestItem] {
        let day = Self.dayFormatter.string(from: since)
        return try await GitHubCLI.runJSON([
            "search", "prs",
            "--author=@me",
            "--state=closed",
            "--closed=>=\(day)",
            "--sort", "updated",
            "--order", "desc",
            "--limit", String(limit),
            "--json", Self.jsonFields,
        ])
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
