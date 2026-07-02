import Foundation
import Observation

/// Multi-conversation chat store backing the standalone chat app: owns the list
/// of conversations, the current selection, and all message mutations, with
/// automatic JSON persistence (ADR-6, revised: chat history IS persisted).
///
/// Replaces the earlier single-session `ChatSession`. Streaming assistant
/// replies are mutated in place on the current conversation by message id.
@MainActor
@Observable
final class ChatStore {
    private(set) var conversations: [Conversation]
    private(set) var currentID: UUID?

    private let store: ConversationStore

    init(store: ConversationStore = ConversationStore()) {
        self.store = store
        let loaded = store.load().sorted { $0.updatedAt > $1.updatedAt }
        self.conversations = loaded
        self.currentID = loaded.first?.id
    }

    // MARK: - Current conversation

    var current: Conversation? {
        guard let currentID else { return nil }
        return conversations.first { $0.id == currentID }
    }

    /// Messages of the current conversation (empty when none selected).
    var messages: [Message] {
        current?.messages ?? []
    }

    /// History for the LLM client: excludes system messages and any
    /// still-streaming placeholder.
    var historyMessages: [Message] {
        (current?.messages ?? []).filter { $0.role != .system && !$0.isStreaming }
    }

    private func index(of id: UUID?) -> Int? {
        guard let id else { return nil }
        return conversations.firstIndex { $0.id == id }
    }

    // MARK: - Conversation lifecycle

    /// Create a new (optionally seeded) conversation and make it current.
    /// Seeded messages are used by the minimal-box auto-upgrade to carry prior
    /// one-shot turns over as context.
    @discardableResult
    func newConversation(seeding seed: [Message] = []) -> UUID {
        let title = seed.first(where: { $0.role == .user }).map { Conversation.makeTitle(from: $0.text) } ?? ""
        let convo = Conversation(title: title, messages: seed)
        conversations.insert(convo, at: 0)
        currentID = convo.id
        if !seed.isEmpty { persist() }
        return convo.id
    }

    /// Ensure there is a current conversation to receive messages.
    @discardableResult
    func ensureCurrent() -> UUID {
        if let currentID, conversations.contains(where: { $0.id == currentID }) {
            return currentID
        }
        return newConversation()
    }

    /// Discard everything and start a single fresh conversation ("renew").
    func reset() {
        conversations = []
        currentID = nil
        newConversation()
    }

    func select(_ id: UUID) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        currentID = id
    }

    func deleteConversation(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id {
            currentID = conversations.first?.id
        }
        persist()
    }

    // MARK: - Message mutations (operate on the current conversation)

    @discardableResult
    func appendUser(_ text: String) -> UUID {
        ensureCurrent()
        let message = Message(role: .user, text: text)
        mutateCurrent { $0.messages.append(message) }
        return message.id
    }

    @discardableResult
    func startAssistant(streaming: Bool = true) -> UUID {
        ensureCurrent()
        let message = Message(role: .assistant, text: "", isStreaming: streaming)
        mutateCurrent { $0.messages.append(message) }
        return message.id
    }

    func appendToken(_ id: UUID, _ token: String) {
        mutateCurrent { convo in
            if let i = convo.messages.firstIndex(where: { $0.id == id }) {
                convo.messages[i].text += token
            }
        }
    }

    func updateText(_ id: UUID, _ text: String) {
        mutateCurrent { convo in
            if let i = convo.messages.firstIndex(where: { $0.id == id }) {
                convo.messages[i].text = text
            }
        }
    }

    /// Mark the streaming message finished and persist the completed turn.
    func finish(_ id: UUID) {
        mutateCurrent { convo in
            if let i = convo.messages.firstIndex(where: { $0.id == id }) {
                convo.messages[i].isStreaming = false
            }
        }
        persist()
    }

    // MARK: - Internals

    private func mutateCurrent(_ body: (inout Conversation) -> Void) {
        guard let i = index(of: currentID) else { return }
        var convo = conversations[i]
        body(&convo)
        convo.updatedAt = Date()
        // Auto-title from the first user message once available.
        if convo.title.isEmpty, let firstUser = convo.messages.first(where: { $0.role == .user }) {
            convo.title = Conversation.makeTitle(from: firstUser.text)
        }
        conversations[i] = convo
    }

    /// Persist only non-empty conversations so abandoned blank chats don't
    /// accumulate on disk.
    private func persist() {
        store.save(conversations.filter { !$0.messages.isEmpty })
    }
}
