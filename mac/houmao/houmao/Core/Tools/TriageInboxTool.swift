import Foundation

/// Triage recent Gmail: drop routine noise (promotions / social / subscription)
/// via `MailImportance`, cluster the rest with `MailGrouping`, and attach a
/// three-sentence summary per important cluster via `MailWatcher.summarize`.
/// Read-only. Reuses exactly the `/mail` watcher's denoise + summarize path.
///
/// Summaries are cached in the shared `MailMemoryStore` (keyed by cluster
/// signature = sorted message ids), so a cluster with no new mail costs nothing
/// on repeat calls; only cache misses spend the LLM budget. Higher-level
/// prioritization ("先看哪些") is left to the agent, on top of this digest.
struct TriageInboxTool: AgentTool {
    let name = "triage_inbox"
    let description = "Triage recent unread Gmail: drop routine noise (promotions/social/subscriptions) and return only the important messages, each with a three-sentence summary (背景/目的/处理). Use this to quickly see what matters."

    var parametersSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Gmail search query. Defaults to \"is:unread in:inbox newer_than:30d\"."),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max messages to scan (default 100, max 200)."),
                ]),
            ]),
        ])
    }

    /// Max NEW LLM summaries per call (cache hits are free and unlimited). Mirrors
    /// the watcher's budget so a busy inbox can't fan out unbounded LLM calls.
    private let summaryBudget = 8

    private let provider: any MailProvider
    private let customTags: [MailTag]
    private let memory: MailMemoryStore
    private let summarize: @Sendable (MailCluster) async -> String?

    init(
        provider: any MailProvider,
        customTags: [MailTag],
        memory: MailMemoryStore = MailMemoryStore(),
        summarize: @escaping @Sendable (MailCluster) async -> String? = { await MailWatcher.summarize($0) }
    ) {
        self.provider = provider
        self.customTags = customTags
        self.memory = memory
        self.summarize = summarize
    }

    func invoke(arguments: JSONValue) async throws -> String {
        let query = arguments["query"]?.stringValue ?? "is:unread in:inbox newer_than:30d"
        let limit = min(max(arguments["limit"]?.intValue ?? 100, 1), 200)

        let ids = try await provider.listMessages(query: query, maxResults: limit)
        guard !ids.isEmpty else { return "No messages found for query \"\(query)\"." }

        let messages = try await provider.fetchMetadata(ids: ids)
        let clusters = MailGrouping.group(messages, customTags: customTags)
        let important = clusters.filter { !MailImportance.isRoutine($0) }
        guard !important.isEmpty else {
            return "扫描了 \(messages.count) 封邮件，没有需要关注的重点（其余为促销/社交/订阅类噪音）。"
        }

        // Shared summary cache (with the watcher and /mail). Cache hits are free;
        // only misses spend the LLM budget, so an unchanged inbox costs nothing.
        var state = memory.load()
        var generated = 0
        var dirty = false
        var lines: [String] = []
        for cluster in important {
            let subject = cluster.representativeSubject.isEmpty ? "(无主题)" : cluster.representativeSubject
            let header = "▸ \(subject) · \(cluster.primary) · \(cluster.count) 封"
            let sig = MailSignature.cluster(cluster)
            var summary = state.summaries[sig]
            if summary == nil, generated < summaryBudget {
                summary = await summarize(cluster)
                if let generatedSummary = summary {
                    state.summaries[sig] = generatedSummary
                    generated += 1
                    dirty = true
                }
            }
            lines.append(summary.map { "\(header)\n\($0)" } ?? header)
        }
        if dirty { try? memory.save(state) }

        let routineCount = clusters.count - important.count
        let footer = routineCount > 0 ? "\n\n（已忽略 \(routineCount) 组噪音）" : ""
        return lines.joined(separator: "\n\n") + footer
    }
}
