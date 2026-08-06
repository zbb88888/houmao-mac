import Foundation

/// Reads the full body of one Gmail message by id, reusing `MailProvider`
/// (`fetchFull`). Read-only. The agent typically calls this after
/// `list_recent_mail` to analyze a specific message.
struct ReadMailTool: AgentTool {
    let name = "read_mail"
    let description = "Read the full body of a Gmail message by id (get the id from list_recent_mail)."

    var parametersSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "id": .object([
                    "type": .string("string"),
                    "description": .string("The Gmail message id."),
                ]),
            ]),
            "required": .array([.string("id")]),
        ])
    }

    private let provider: any MailProvider

    init(provider: any MailProvider) { self.provider = provider }

    func invoke(arguments: JSONValue) async throws -> String {
        guard let id = arguments["id"]?.stringValue, !id.isEmpty else {
            return "error: missing required argument \"id\"."
        }
        let detail = try await provider.fetchFull(id: id)
        return """
        from: \(detail.from)
        to: \(detail.to)
        subject: \(detail.subject)
        date: \(detail.date)

        \(detail.body)
        """
    }
}
