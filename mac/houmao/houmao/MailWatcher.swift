import Foundation

/// Proactive mail watcher (docs/proactive-agency.md §8): on the agent's poll
/// cycle, cluster recent unread mail, pre-warm a one-line summary for genuinely
/// new & non-routine clusters (cached so `/mail` is instant), and surface those
/// as inbox events.
///
/// Unlike `GitHubWatcher` (pure sensing), this also writes the summary cache as
/// a side effect — the natural home for mail proactivity. It never mutates mail
/// (no delete / archive / mark-read); it only reads, summarizes, and suggests.
struct MailWatcher: Watcher {
    let id = "mail"

    /// Cap clusters summarized per poll to bound LLM cost.
    private let summaryBudget = 5

    func poll() async throws -> [AgentEvent] {
        guard !AppSettings.shared.googleClientID.isEmpty, await GoogleAccount.isConnected else {
            return []
        }
        let provider = GmailProvider(accessTokenProvider: { try await GoogleAccount.accessToken() })
        let ids = try await provider.listMessages(query: "is:unread in:inbox newer_than:30d", maxResults: 200)
        guard !ids.isEmpty else { return [] }
        let messages = try await provider.fetchMetadata(ids: ids)
        let clusters = MailGrouping.group(messages, customTags: AppSettings.shared.mailTags)

        let store = MailMemoryStore()
        var state = store.load()
        var events: [AgentEvent] = []
        var summarized = 0
        let now = Date()

        for cluster in clusters {
            let sig = MailSignature.cluster(cluster)
            let family = MailSignature.family(cluster)
            // Only genuinely new & non-routine clusters are surfaced / summarized.
            guard !MailMemoryStore.isSeen(state, clusterSig: sig, familyKey: family) else { continue }
            guard !Self.isLowPriority(cluster.category) else { continue }

            // Pre-warm a one-line summary once per unique cluster (cost-bounded),
            // so opening `/mail` shows it without waiting on the LLM.
            if state.summaries[sig] == nil, summarized < summaryBudget,
               let summary = await Self.summarize(cluster) {
                state.summaries[sig] = summary
                summarized += 1
            }

            events.append(AgentEvent(
                id: sig,
                kind: .newMailCluster,
                title: cluster.representativeSubject.isEmpty ? "(无主题)" : cluster.representativeSubject,
                subtitle: "\(cluster.primary) · \(cluster.count) 封",
                url: "",
                detectedAt: now,
                suggestedCommand: "/mail"
            ))
        }

        try? store.save(state)
        return events
    }

    /// Promotions / social are routine noise — skip them to save LLM cost.
    private static func isLowPriority(_ category: MailCategory) -> Bool {
        category == .promotions || category == .social
    }

    /// One-line summary from metadata only (subjects + snippets); no `fetchFull`,
    /// so it's a single cheap LLM call per cluster.
    private static func summarize(_ cluster: MailCluster) async -> String? {
        guard let model = AppSettings.shared.resolveModel(named: nil) else { return nil }
        let lines = cluster.messages.prefix(5)
            .map { "· \($0.subject) — \($0.snippet)" }
            .joined(separator: "\n")
        let prompt = "用一句话（20 字内、简体中文）概括这组邮件的主题，并点明是否需要我处理：\n\(lines)"
        let client = AiTxtClient(
            baseURL: model.provider.apiHost,
            model: model.model,
            apiKey: model.provider.apiKey
        )
        return try? await client.ask(question: prompt, attachments: [])
    }
}
