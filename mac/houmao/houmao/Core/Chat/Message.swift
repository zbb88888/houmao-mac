import Foundation

/// One message in a chat session.
///
/// The chat is the universal information bus: user input, captured text, and
/// assistant replies are all messages. Platform-agnostic Core type so the same
/// model backs both the macOS `/chat` mode and the iOS chat UI.
struct Message: Identifiable, Equatable, Sendable, Codable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    let id: UUID
    let role: Role
    var text: String
    let createdAt: Date
    /// True while an assistant message is still being streamed in.
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        createdAt: Date = Date(),
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.createdAt = createdAt
        self.isStreaming = isStreaming
    }
}
