import Testing
import Foundation
@testable import houmao

@MainActor
struct ChatStoreTests {

    /// Fresh store backed by a unique temp file so each test is isolated.
    private func makeStore() -> (ChatStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("houmao-chatstore-\(UUID().uuidString).json")
        return (ChatStore(store: ConversationStore(fileURL: url)), url)
    }

    @Test func startsEmpty() {
        let (store, _) = makeStore()
        #expect(store.conversations.isEmpty)
        #expect(store.current == nil)
        #expect(store.messages.isEmpty)
    }

    @Test func newConversationBecomesCurrent() {
        let (store, _) = makeStore()
        let id = store.newConversation()
        #expect(store.currentID == id)
        #expect(store.conversations.count == 1)
    }

    @Test func appendUserCreatesConversationAndTitle() {
        let (store, _) = makeStore()
        store.appendUser("Translate this sentence please")
        #expect(store.conversations.count == 1)
        #expect(store.messages.count == 1)
        #expect(store.current?.title == "Translate this sentence please")
    }

    @Test func streamingAssistantUpdatesCurrentMessage() {
        let (store, _) = makeStore()
        store.appendUser("hi")
        let id = store.startAssistant(streaming: true)
        store.appendToken(id, "Hel")
        store.appendToken(id, "lo")
        #expect(store.messages.last?.text == "Hello")
        #expect(store.messages.last?.isStreaming == true)

        store.finish(id)
        #expect(store.messages.last?.isStreaming == false)
    }

    @Test func historyExcludesStreamingPlaceholder() {
        let (store, _) = makeStore()
        store.appendUser("q")
        _ = store.startAssistant(streaming: true)
        // The empty streaming assistant must not be sent back as history.
        #expect(store.historyMessages.count == 1)
        #expect(store.historyMessages.first?.role == .user)
    }

    @Test func selectSwitchesCurrentConversation() {
        let (store, _) = makeStore()
        let first = store.newConversation(seeding: [Message(role: .user, text: "one")])
        let second = store.newConversation(seeding: [Message(role: .user, text: "two")])
        #expect(store.currentID == second)

        store.select(first)
        #expect(store.currentID == first)
        #expect(store.messages.first?.text == "one")
    }

    @Test func deleteConversationUpdatesSelection() {
        let (store, _) = makeStore()
        let first = store.newConversation(seeding: [Message(role: .user, text: "a")])
        _ = store.newConversation(seeding: [Message(role: .user, text: "b")])

        store.deleteConversation(store.currentID!)
        #expect(store.conversations.count == 1)
        #expect(store.currentID == first)
    }

    @Test func nonEmptyConversationsPersistAndReload() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("houmao-persist-\(UUID().uuidString).json")
        do {
            let store = ChatStore(store: ConversationStore(fileURL: url))
            store.appendUser("remember me")
            let id = store.startAssistant(streaming: true)
            store.updateText(id, "sure")
            store.finish(id) // persists on finish
        }
        // Reload from the same file in a new store.
        let reloaded = ChatStore(store: ConversationStore(fileURL: url))
        #expect(reloaded.conversations.count == 1)
        #expect(reloaded.messages.count == 2)
        #expect(reloaded.current?.title == "remember me")

        try? FileManager.default.removeItem(at: url)
    }

    @Test func emptyConversationsAreNotPersisted() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("houmao-empty-\(UUID().uuidString).json")
        do {
            let store = ChatStore(store: ConversationStore(fileURL: url))
            _ = store.newConversation() // empty, then force a persist via delete
            store.appendUser("x")
            let id = store.startAssistant()
            store.finish(id)
            _ = store.newConversation() // a second, empty one
            store.deleteConversation(store.currentID!) // triggers persist
        }
        let reloaded = ChatStore(store: ConversationStore(fileURL: url))
        // Only the conversation with messages survives.
        #expect(reloaded.conversations.count == 1)

        try? FileManager.default.removeItem(at: url)
    }
}
