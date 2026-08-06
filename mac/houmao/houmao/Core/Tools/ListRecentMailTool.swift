import Foundation

/// Lists recent Gmail messages (metadata only), reusing `MailProvider` — the
/// same read path the `/mail` panel uses. Read-only. The returned ids can be
/// passed to `read_mail` to drill into a specific message (multi-step analysis).
struct ListRecentMailTool: AgentTool {
    let name = "list_recent_mail"
    let description = "List recent Gmail messages (id, sender, subject, snippet). Use the id with read_mail to read a message's full body. Defaults to unread mail."

    var parametersSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "query": .object([
                    "type": .string("string"),
                    "description": .string("Gmail search query, e.g. \"is:unread\", \"from:foo@bar.com\", \"newer_than:7d\". Defaults to \"is:unread\"."),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max messages to return (default 20, max 50)."),
                ]),
            ]),
        ])
    }

    private let provider: any MailProvider

    init(provider: any MailProvider) { self.provider = provider }

    func invoke(arguments: JSONValue) async throws -> String {
        let query = arguments["query"]?.stringValue ?? "is:unread"
        let limit = min(max(arguments["limit"]?.intValue ?? 20, 1), 50)

        let ids = try await provider.listMessages(query: query, maxResults: limit)
        guard !ids.isEmpty else { return "No messages found for query \"\(query)\"." }

        let messages = try await provider.fetchMetadata(ids: Array(ids.prefix(limit)))
        let sorted = messages.sorted { $0.date > $1.date }
        return sorted.map { m in
            "- \(m.subject)  —  \(m.from)  [id: \(m.id)]\n  \(m.snippet)"
        }.joined(separator: "\n")
    }
}
