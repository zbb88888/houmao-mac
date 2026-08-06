import Foundation

/// Lists the current user's GitHub pull requests, reusing `PullRequestProvider`
/// (the same `gh` info flow the PR panel triggers manually). Read-only.
struct ListPullRequestsTool: AgentTool {
    let name = "list_pull_requests"
    let description = "List the current user's GitHub pull requests. Use filter \"authored\" for PRs I opened, or \"review_requested\" for PRs awaiting my review."

    var parametersSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "filter": .object([
                    "type": .string("string"),
                    "enum": .array([.string("authored"), .string("review_requested")]),
                    "description": .string("Which PRs to list. Defaults to \"authored\"."),
                ]),
            ]),
        ])
    }

    private let provider: PullRequestProvider

    init(provider: PullRequestProvider = PullRequestProvider()) {
        self.provider = provider
    }

    func invoke(arguments: JSONValue) async throws -> String {
        let filter = arguments["filter"]?.stringValue ?? "authored"
        let items: [PullRequestItem]
        switch filter {
        case "review_requested": items = try await provider.fetchReviewRequested()
        default: items = try await provider.fetchOpen()
        }
        guard !items.isEmpty else { return "No pull requests found for filter \"\(filter)\"." }
        return items.map { pr in
            let draft = pr.isDraftPR ? " [draft]" : ""
            return "- \(pr.repository.nameWithOwner) — \(pr.title)\(draft)\n  \(pr.url)"
        }.joined(separator: "\n")
    }
}
