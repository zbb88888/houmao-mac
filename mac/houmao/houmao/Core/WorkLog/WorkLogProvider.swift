import Foundation

/// Fetches the current user's pull requests and issues (created on/after a
/// cut-off) via the GitHub CLI, plus each item's body + commit headlines — the
/// raw material the work-log feature summarizes. Reuses the shared `GitHubCLI`
/// subprocess helper; auth reuses the user's `gh auth login` session.
struct WorkLogProvider {
    private static let listFields = "number,title,url,repository,createdAt"

    /// PRs authored by the current user, created on/after `since`, oldest first
    /// (so summaries are produced in chronological order).
    func fetchPRs(since: Date, limit: Int = 300) async throws -> [WorkItemRef] {
        try await GitHubCLI.runJSON([
            "search", "prs",
            "--author=@me",
            "--created=>=\(Self.day(since))",
            "--sort", "created",
            "--order", "asc",
            "--limit", String(limit),
            "--json", Self.listFields,
        ])
    }

    /// Issues authored by the current user, created on/after `since`, oldest
    /// first. `gh search issues` excludes PRs by default.
    func fetchIssues(since: Date, limit: Int = 300) async throws -> [WorkItemRef] {
        try await GitHubCLI.runJSON([
            "search", "issues",
            "--author=@me",
            "--created=>=\(Self.day(since))",
            "--sort", "created",
            "--order", "asc",
            "--limit", String(limit),
            "--json", Self.listFields,
        ])
    }

    /// The content fed to the summarizer for `ref`: its body plus, for PRs, the
    /// commit headlines (a compact signal of what changed without pulling a
    /// possibly-huge diff).
    func fetchContext(_ ref: WorkItemRef, kind: WorkKind) async throws -> String {
        switch kind {
        case .pr:
            let detail: PRDetail = try await GitHubCLI.runJSON([
                "pr", "view", ref.url, "--json", "body,commits",
            ])
            let commits = detail.commits.prefix(30)
                .map { "- \($0.messageHeadline)" }
                .joined(separator: "\n")
            return Self.compose(body: detail.body, extra: commits.isEmpty ? nil : "提交：\n\(commits)")
        case .issue:
            let detail: IssueDetail = try await GitHubCLI.runJSON([
                "issue", "view", ref.url, "--json", "body",
            ])
            return Self.compose(body: detail.body, extra: nil)
        }
    }

    // MARK: - Detail decoding

    private struct PRDetail: Decodable {
        let body: String
        let commits: [Commit]
        struct Commit: Decodable { let messageHeadline: String }
    }

    private struct IssueDetail: Decodable {
        let body: String
    }

    // MARK: - Helpers

    /// Cap the body so a single huge PR description can't blow the LLM context.
    private static func compose(body: String, extra: String?) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = trimmed.count > 4000 ? String(trimmed.prefix(4000)) + "…" : trimmed
        return [capped.isEmpty ? nil : "正文：\n\(capped)", extra]
            .compactMap { $0 }
            .joined(separator: "\n\n")
    }

    private static func day(_ date: Date) -> String {
        Self.dayFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
