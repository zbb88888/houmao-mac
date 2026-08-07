import Foundation

/// A parsed GitHub issue/PR reference.
struct GitHubRef: Sendable, Equatable {
    let owner: String
    let repo: String
    let number: Int
    /// Stable, filesystem-friendly id for the result document.
    var slug: String { "\(owner)-\(repo)-\(number)" }
}

enum AnalyzeError: LocalizedError {
    case noProvider
    case noRepo(String)
    case emptyReport

    var errorDescription: String? {
        switch self {
        case .noProvider: return "未配置 provider（设置 ⌘,）。"
        case .noRepo(let repo): return "本地未找到仓库 \(repo)（需先 clone 到 code dir 下）。"
        case .emptyReport: return "分析没有产出内容。"
        }
    }
}

/// §7 async producer tool: wraps ghia (`IssueAnalyzer`) as a background job whose
/// full report is written to a result document. `mode` = "pr" or "issue". The
/// agent reads the document (via `read_document`) once the completion event fires.
struct AnalyzeGitHubTool: AgentTool {
    let mode: String
    let jobStore: JobStore
    let resultsRoot: URL?
    /// Does the work and returns the full report. Injectable for tests; the
    /// default runs ghia against the local repo.
    let run: @Sendable (_ mode: String, _ ref: GitHubRef, _ url: String) async throws -> String

    init(
        mode: String,
        jobStore: JobStore,
        resultsRoot: URL? = nil,
        run: @escaping @Sendable (String, GitHubRef, String) async throws -> String = {
            try await AnalyzeGitHubTool.defaultRun(mode: $0, ref: $1, url: $2)
        }
    ) {
        self.mode = mode
        self.jobStore = jobStore
        self.resultsRoot = resultsRoot
        self.run = run
    }

    var name: String { mode == "pr" ? "analyze_pr" : "analyze_issue" }

    var description: String {
        mode == "pr"
            ? "Deep-review a GitHub pull request against the local repo (multi-stage ghia: PR discussion + diff + code). Runs as a background job; when it finishes, read the result document for the report."
            : "Analyze a GitHub issue against the local repo (ghia). Runs as a background job; when it finishes, read the result document for the report."
    }

    var parametersSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "url": .object([
                    "type": .string("string"),
                    "description": .string("The GitHub \(mode) URL."),
                ]),
            ]),
            "required": .array([.string("url")]),
        ])
    }

    func dispatch(arguments: JSONValue) -> AgentJob? {
        guard let url = arguments["url"]?.stringValue, let ref = Self.parse(url) else { return nil }
        let docURL = AgentResults.documentURL(kind: mode, id: ref.slug, root: resultsRoot)
        let job = AgentJob(
            id: ref.slug,
            kind: mode,
            title: "\(mode == "pr" ? "PR" : "Issue") \(ref.owner)/\(ref.repo)#\(ref.number)",
            documentPath: docURL.path
        )
        // Run the (possibly long) work off the loop; report completion via JobStore.
        let mode = self.mode, run = self.run, store = self.jobStore
        Task {
            await store.start(job)
            do {
                let report = try await run(mode, ref, url)
                try AgentResults.write(report, to: docURL)
                await store.finish(job.id, status: .succeeded)
            } catch {
                await store.finish(job.id, status: .failed, error: error.localizedDescription)
            }
        }
        return job
    }

    /// Reached only when `dispatch` returned nil (unparseable URL).
    func invoke(arguments: JSONValue) async throws -> String {
        "error: 无法识别 GitHub \(mode) URL：\(arguments["url"]?.stringValue ?? "")"
    }

    static func parse(_ url: String) -> GitHubRef? {
        let pattern = #"github\.com/([^/]+)/([^/]+)/(?:issues|pull)/(\d+)"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let o = Range(m.range(at: 1), in: url),
              let r = Range(m.range(at: 2), in: url),
              let n = Range(m.range(at: 3), in: url),
              let num = Int(url[n]) else { return nil }
        return GitHubRef(owner: String(url[o]), repo: String(url[r]), number: num)
    }

    /// Default work: run ghia against the local repo and collect its full report.
    static func defaultRun(mode: String, ref: GitHubRef, url: String) async throws -> String {
        guard let resolved = AppSettings.shared.resolveModel(named: nil) else { throw AnalyzeError.noProvider }
        guard let repoPath = AppSettings.shared.resolveRepoPath(owner: ref.owner, repo: ref.repo) else {
            throw AnalyzeError.noRepo(ref.repo)
        }
        let analyzer = IssueAnalyzer(config: .init(
            binaryPath: IssueAnalyzer.defaultBinaryPath,
            apiKey: resolved.provider.apiKey,
            baseURL: resolved.provider.apiHost + "/v1",
            model: resolved.model,
            contextTokens: resolved.provider.contextTokens
        ))
        var report = ""
        for try await event in analyzer.stream(url: url, repoPath: repoPath, mode: mode) {
            if case .content(let c) = event { report += c }
        }
        if report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw AnalyzeError.emptyReport }
        return report
    }
}
