import Foundation

/// A persisted, multi-turn chat conversation — the unit shown in the chat app's
/// sidebar. Platform-agnostic Core type (ADR-4): persistence and UI live in the
/// shells, but the model is shared by macOS today and iOS later.
struct Conversation: Identifiable, Equatable, Codable, Sendable {
    let id: UUID
    var title: String
    var messages: [Message]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        title: String = "",
        messages: [Message] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.messages = messages
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// First user-visible line, trimmed to a sidebar-friendly length. Used to
    /// auto-name a conversation from its first user message (Chatbox-style).
    static func makeTitle(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed
        let clipped = String(firstLine.prefix(40)).trimmingCharacters(in: .whitespaces)
        return clipped.isEmpty ? "New Chat" : clipped
    }
}
