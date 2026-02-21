import Foundation
import SwiftUI
import Combine
import HoumaoCore

enum Panel: Equatable {
    case none
    case chat
    case history
    case help
}

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
    var panel: Panel = .none {
        didSet { objectWillChange.send() }
    }

    private let llmClient: LLMClient
    private var currentTask: Task<Void, Never>?
    var usageTracker: UsageTracker?

    /// Commands: single-letter input → panel toggle.
    /// Add new entries here for future special commands.
    private let commands: [String: Panel] = [
        "b": .history,
        "h": .help,
    ]

    init(llmClient: LLMClient) {
        self.llmClient = llmClient
    }

    func submit(onShowHistory: () -> Void) {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Check commands
        if let target = commands[trimmed.lowercased()] {
            inputText = ""
            if target == .history { onShowHistory() }
            panel = (panel == target) ? .none : target
            return
        }

        // Normal LLM query
        lastUserText = trimmed
        lastLLMReply = nil
        inputText = ""
        isLoading = true
        panel = .chat

        usageTracker?.record(text: trimmed)

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
        panel = .none
        inputText = ""
    }
}
