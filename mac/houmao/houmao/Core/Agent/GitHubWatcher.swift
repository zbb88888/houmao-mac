import Foundation

/// Watches GitHub for items that want the user's attention: issues newly
/// assigned to them and PRs requesting their review. Reuses the existing `gh`
/// providers; AI-free sensing. Each item carries a `suggestedCommand` so the
/// inbox can trigger the matching `/issue` / `/pr` analysis with one click.
struct GitHubWatcher: Watcher {
    let id = "github"

    private let issues = IssueProvider()
    private let prs = PullRequestProvider()

    func poll() async throws -> [AgentEvent] {
        async let assigned = issues.fetchAssigned()
        async let reviewRequested = prs.fetchReviewRequested()
        let (assignedResult, prResult) = try await (assigned, reviewRequested)
        let now = Date()

        let issueEvents = assignedResult.map { item in
            AgentEvent(
                id: item.url,
                kind: .assignedIssue,
                title: item.title.isEmpty ? "(无标题)" : item.title,
                subtitle: item.repository.nameWithOwner,
                url: item.url,
                detectedAt: now,
                suggestedCommand: "/issue \(item.url)"
            )
        }
        let prEvents = prResult.map { item in
            AgentEvent(
                id: item.url,
                kind: .reviewRequestedPR,
                title: item.title.isEmpty ? "(无标题)" : item.title,
                subtitle: item.repository.nameWithOwner,
                url: item.url,
                detectedAt: now,
                suggestedCommand: "/pr \(item.url)"
            )
        }
        return prEvents + issueEvents
    }
}
