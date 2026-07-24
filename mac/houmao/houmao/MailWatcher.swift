import Foundation

/// Proactive mail watcher (docs/proactive-agency.md §8): on the agent's poll
/// cycle, cluster recent unread mail, and for each new **non-routine** cluster
/// pre-warm a three-sentence summary (背景 / 目的 / 是否需进一步处理) via one
/// LLM call (routine noise is filtered heuristically, no LLM), plus surface the
/// cluster as an inbox event. Results are cached so `/mail` opens instant.
///
/// Unlike `GitHubWatcher` (pure sensing), this writes the summary cache as a
/// side effect. It never mutates mail (no delete / archive / mark read); it only
/// reads, summarizes, and surfaces.
struct MailWatcher: Watcher {
    let id = "mail"

    /// Cap LLM summaries per poll to bound cost.
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
        var generated = 0
        let now = Date()

        for cluster in clusters {
            // Routine noise (promotions / social / subscription) isn't pushed to
            // the proactive inbox; `/mail` still summarizes it on open.
            guard !MailImportance.isRoutine(cluster) else { continue }

            let sig = MailSignature.cluster(cluster)
            // Pre-warm the summary once per unique cluster (LLM budget-bounded).
            if state.summaries[sig] == nil, generated < summaryBudget,
               let summary = await Self.summarize(cluster) {
                state.summaries[sig] = summary
                generated += 1
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

    /// Generate a three-sentence summary (背景 / 目的 / 是否需进一步处理) for a
    /// cluster via one LLM call over metadata only (subjects + snippets). `nil`
    /// when no model is configured or the call fails. Shared by the watcher
    /// (pre-warm) and `MailViewModel` (on-demand fill when opening `/mail`).
    static func summarize(_ cluster: MailCluster) async -> String? {
        guard let model = AppSettings.shared.resolveModel(named: nil) else { return nil }
        let lines = cluster.messages.prefix(5)
            .map { "· \($0.subject) — \($0.snippet)" }
            .joined(separator: "\n")
        let prompt = """
        下面是一组邮件。请用三句话（每句简体中文、尽量简短）分别总结：背景（这组邮件涉及什么）、目的（对方/系统想让我知道或做什么）、是否需要进一步处理（要不要我回复/操作，及大致该做什么）。
        严格按三行回复，不要多余内容：
        背景: <一句话>
        目的: <一句话>
        处理: <一句话>

        \(lines)
        """
        let client = AiTxtClient(
            baseURL: model.provider.apiHost,
            model: model.model,
            apiKey: model.provider.apiKey
        )
        guard let reply = try? await client.ask(question: prompt, attachments: []) else { return nil }
        let summary = parse(reply)
        return summary.isEmpty ? nil : summary
    }

    /// Parse the three-line `背景:` / `目的:` / `处理:` reply into a summary with
    /// each labelled line joined by a newline. Tolerant of missing lines; falls
    /// back to the whole reply when none of the labelled lines are present.
    static func parse(_ reply: String) -> String {
        func value(after line: Substring) -> String {
            guard let colon = line.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return "" }
            return String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }

        var background = ""
        var purpose = ""
        var action = ""
        for raw in reply.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)[...]
            if line.hasPrefix("背景") {
                background = value(after: line)
            } else if line.hasPrefix("目的") {
                purpose = value(after: line)
            } else if line.hasPrefix("处理") {
                action = value(after: line)
            }
        }

        var parts: [String] = []
        if !background.isEmpty { parts.append("背景：\(background)") }
        if !purpose.isEmpty { parts.append("目的：\(purpose)") }
        if !action.isEmpty { parts.append("处理：\(action)") }
        return parts.isEmpty
            ? reply.trimmingCharacters(in: .whitespacesAndNewlines)
            : parts.joined(separator: "\n")
    }
}
