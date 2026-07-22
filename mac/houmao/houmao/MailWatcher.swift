import Foundation

/// Proactive mail watcher (docs/proactive-agency.md §8): on the agent's poll
/// cycle, cluster recent unread mail, and for each new **non-routine** cluster
/// classify importance ("重点/一般") + a one-line summary via one LLM call
/// (routine noise is filtered heuristically, no LLM). Results are cached so
/// `/mail` is instant, and the cluster is surfaced as an inbox event (important
/// ones highlighted).
///
/// Unlike `GitHubWatcher` (pure sensing), this writes the summary/importance
/// cache as a side effect. It never mutates mail (no delete / archive / mark
/// read); it only reads, judges, and suggests.
struct MailWatcher: Watcher {
    let id = "mail"

    /// Cap LLM classifications per poll to bound cost.
    private let classifyBudget = 5

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
        var classified = 0
        let now = Date()

        for cluster in clusters {
            // Routine noise (promotions / social / subscription) isn't pushed to
            // the proactive inbox; it stays visible in `/mail` (collapsed).
            guard !MailImportance.isRoutine(cluster) else { continue }

            let sig = MailSignature.cluster(cluster)
            var important = state.important.contains(sig)
            // Classify once per unique cluster (LLM budget-bounded).
            if state.summaries[sig] == nil, classified < classifyBudget,
               let result = await Self.classify(cluster) {
                state.summaries[sig] = result.summary
                if result.important { state.important.insert(sig) }
                important = result.important
                classified += 1
            }

            events.append(AgentEvent(
                id: sig,
                kind: .newMailCluster,
                title: cluster.representativeSubject.isEmpty ? "(无主题)" : cluster.representativeSubject,
                subtitle: "\(cluster.primary) · \(cluster.count) 封",
                url: "",
                detectedAt: now,
                suggestedCommand: "/mail",
                important: important
            ))
        }

        try? store.save(state)
        return events
    }

    /// One LLM call over metadata only (subjects + snippets): returns whether the
    /// cluster is a "重点" plus a one-line summary. `nil` when no model is
    /// configured or the call fails (caller degrades to heuristic importance).
    private static func classify(_ cluster: MailCluster) async -> (summary: String, important: Bool)? {
        guard let model = AppSettings.shared.resolveModel(named: nil) else { return nil }
        let lines = cluster.messages.prefix(5)
            .map { "· \($0.subject) — \($0.snippet)" }
            .joined(separator: "\n")
        let prompt = """
        下面是一组邮件。判断它对我是否是「重点」（需要我尽快阅读/回复/处理；促销、社交、纯自动通知不算重点），并用一句话（20 字内、简体中文）概括。
        严格按两行回复，不要多余内容：
        重点: 是 或 否
        摘要: <一句话>

        \(lines)
        """
        let client = AiTxtClient(
            baseURL: model.provider.apiHost,
            model: model.model,
            apiKey: model.provider.apiKey
        )
        guard let reply = try? await client.ask(question: prompt, attachments: []) else { return nil }
        return parse(reply)
    }

    /// Parse the two-line `重点:` / `摘要:` reply; tolerant of missing lines.
    static func parse(_ reply: String) -> (summary: String, important: Bool) {
        var important = false
        var summary = ""
        for raw in reply.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("重点") {
                // "否" / "不是" → not important; only a bare "是" counts.
                important = line.contains("是") && !line.contains("否") && !line.contains("不")
            } else if line.hasPrefix("摘要") {
                if let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) {
                    summary = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        if summary.isEmpty { summary = reply.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (summary, important)
    }
}
