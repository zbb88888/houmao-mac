import Testing
import Foundation
@testable import houmao

/// Covers `/chat` handling on `MainViewModel`. There is no persistent chat
/// "mode" flag anymore: `/chat` from the minimal box simply opens the standalone
/// chat window (`panel == .chat` + enter notification), and closing it collapses
/// the panel. These assertions exercise only the pure state machine — no network
/// or provider resolution is hit because `/chat` short-circuits before any LLM
/// call.
@MainActor
struct ChatModeTests {
    private func makeVM() -> MainViewModel {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("houmao-chatmode-\(UUID().uuidString).json")
        let store = ChatStore(store: ConversationStore(fileURL: url))
        return MainViewModel(chatStore: store)
    }

    @Test func slashChatOpensChatWindow() {
        let vm = makeVM()
        vm.inputText = "/chat"
        vm.submit()

        #expect(vm.panel == .chat)
        #expect(vm.inputText == "")
    }

    @Test func exitChatModeCollapsesPanel() {
        let vm = makeVM()
        vm.inputText = "/chat"
        vm.submit()
        vm.exitChatMode()

        #expect(vm.panel == .none)
    }

    @Test func slashChatIsCaseInsensitive() {
        let vm = makeVM()
        vm.inputText = "/Chat"
        vm.submit()

        #expect(vm.panel == .chat)
    }

    @Test func openingChatWindowEnsuresCurrentConversation() {
        let vm = makeVM()
        vm.inputText = "/chat"
        vm.submit()

        // Opening the chat window must surface a usable conversation.
        #expect(vm.chatStore.current != nil)
    }

    @Test func resetInputCollapsesPanelButKeepsStore() {
        let vm = makeVM()
        vm.inputText = "/chat"
        vm.submit()
        vm.chatStore.appendUser("persisted turn")

        vm.resetInput()

        // The minimal box collapses, but the persistent store is untouched.
        #expect(vm.panel == .none)
        #expect(vm.chatStore.messages.isEmpty == false)
    }

    // MARK: - Tool-command consistency across surfaces

    @Test func handleToolCommandRecognizesToolsOnly() {
        let vm = makeVM()
        #expect(vm.handleToolCommand("/chat") == true)
        #expect(vm.handleToolCommand("/mail") == true)
        #expect(vm.handleToolCommand("hello world") == false)
        #expect(vm.handleToolCommand("") == false)
    }

    @Test func slashMailConsumedByBothSurfacesIdentically() {
        // `/mail` must be consumed (input cleared, no chat turn created) whether
        // it comes from the minimal box or the chat window — the shared router
        // guarantees the tool set can't drift between surfaces.
        let box = makeVM()
        box.inputText = "/mail"
        box.submit()
        #expect(box.inputText == "")
        #expect(box.chatStore.messages.isEmpty)

        let chat = makeVM()
        chat.inputText = "/mail"
        chat.sendChatTurn()
        #expect(chat.inputText == "")
        #expect(chat.chatStore.messages.isEmpty)
    }

    @Test func slashChatWorksFromChatWindowToo() {
        let vm = makeVM()
        vm.inputText = "/chat"
        vm.sendChatTurn()

        #expect(vm.panel == .chat)
        #expect(vm.inputText == "")
    }
}
