import Foundation

/// Moves Gmail messages to Trash (recoverable), reusing `MailProvider`. This is
/// the first **mutating** tool: `AgentLoop` never runs it automatically — it
/// pauses for the user's confirmation first (ADR-8).
struct TrashMailTool: AgentTool {
    let name = "trash_mail"
    let description = "Move Gmail messages to Trash (recoverable). Provide the message ids from list_recent_mail."
    var isMutating: Bool { true }

    var parametersSchema: JSONValue {
        .object([
            "type": .string("object"),
            "properties": .object([
                "ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Gmail message ids to move to Trash."),
                ]),
            ]),
            "required": .array([.string("ids")]),
        ])
    }

    private let provider: any MailProvider

    init(provider: any MailProvider) { self.provider = provider }

    func invoke(arguments: JSONValue) async throws -> String {
        let ids = arguments["ids"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !ids.isEmpty else { return "error: no message ids provided." }
        try await provider.trashMessages(ids: ids)
        return "已将 \(ids.count) 封邮件移到废纸篓（可恢复）。"
    }
}
