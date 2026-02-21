import Foundation
import SwiftUI
import Combine
import HoumaoCore

@MainActor
final class MainViewModel: ObservableObject {
    nonisolated let objectWillChange = ObservableObjectPublisher()

    var inputText: String = "" {
        didSet { objectWillChange.send() }
    }
    var lastUserText: String? {
        didSet { objectWillChange.send() }
    }
    var lastLLMReply: String? {
        didSet { objectWillChange.send() }
    }
    var isLoading: Bool = false {
        didSet { objectWillChange.send() }
    }
    var isShowingHistory: Bool = false {
        didSet { objectWillChange.send() }
    }

    private let llmClient: LLMClient
    private var currentTask: Task<Void, Never>?

    init(llmClient: LLMClient) {
        self.llmClient = llmClient
    }

    func submit(historyHandler: () -> Void) {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if trimmed.lowercased() == "b" {
            inputText = ""
            historyHandler()
            return
        }

        lastUserText = trimmed
        lastLLMReply = nil
        inputText = ""
        isLoading = true

        currentTask?.cancel()
        currentTask = Task {
            do {
                let reply = try await llmClient.ask(question: trimmed)
                guard !Task.isCancelled else { return }
                self.lastLLMReply = reply
            } catch is CancellationError {
                // Cancelled, do nothing
            } catch {
                self.lastLLMReply = "Error: \(error.localizedDescription)"
            }
            self.isLoading = false
        }
    }

    func clearConversation() {
        currentTask?.cancel()
        lastUserText = nil
        lastLLMReply = nil
        isLoading = false
        inputText = ""
    }

    func toggleHistoryView() {
        isShowingHistory.toggle()
    }
}
