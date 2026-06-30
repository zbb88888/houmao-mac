import Testing
import Foundation
@testable import houmao

/// Covers `/chat` mode toggling on `MainViewModel`. These assertions exercise
/// only the pure state machine — no network or provider resolution is hit
/// because the `/chat` command short-circuits before any LLM call.
@MainActor
struct ChatModeTests {
    private func makeVM() -> MainViewModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("houmao-chatmode-\(UUID().uuidString).json")
        let store = ChatStore(store: ConversationStore(fileURL: url))
        return MainViewModel(chatStore: store)
    }

    @Test func slashChatEntersChatMode() {
        let vm = makeVM()
        vm.inputText = "/chat"
        vm.submit()

        #expect(vm.isChatMode == true)
        #expect(vm.panel == .chat)
        #expect(vm.inputText == "")
    }

    @Test func slashChatTwiceExits() {
        let vm = makeVM()
        vm.inputText = "/chat"
        vm.submit()
        vm.inputText = "/chat"
        vm.submit()

        #expect(vm.isChatMode == false)
        #expect(vm.panel == .none)
    }

    @Test func slashChatIsCaseInsensitive() {
        let vm = makeVM()
        vm.inputText = "/Chat"
        vm.submit()

        #expect(vm.isChatMode == true)
    }

    @Test func enteringChatModeEnsuresCurrentConversation() {
        let vm = makeVM()
        vm.inputText = "/chat"
        vm.submit()

        // Entering chat must surface a usable conversation (continued or fresh).
        #expect(vm.chatStore.current != nil)
    }

    @Test func resetInputLeavesChatModeButKeepsStore() {
        let vm = makeVM()
        vm.inputText = "/chat"
        vm.submit()
        vm.chatStore.appendUser("persisted turn")

        vm.resetInput()

        // The minimal box collapses, but the persistent store is untouched.
        #expect(vm.isChatMode == false)
        #expect(vm.panel == .none)
        #expect(vm.chatStore.messages.isEmpty == false)
    }
}
