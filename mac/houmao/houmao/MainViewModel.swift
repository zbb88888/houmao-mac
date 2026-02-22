import SwiftUI
import Combine

enum Panel: Equatable {
    case none
    case chat
    case history
    case help
}

@MainActor
final class MainViewModel: ObservableObject {
    @Published var inputText: String = ""
    @Published var lastUserText: String?
    @Published var lastLLMReply: String?
    @Published var isLoading: Bool = false
    @Published var panel: Panel = .none

    private let llmClient: LLMClient
    private var currentTask: Task<Void, Never>?
    private(set) var usageTracker: UsageTracker?
    let commandHistory = CommandHistory()

    /// Single-letter commands that toggle panels.
    private let commands: [String: Panel] = [
        "b": .history,
        "h": .help,
    ]

    init(llmClient: LLMClient, usageTracker: UsageTracker? = nil) {
        self.llmClient = llmClient
        self.usageTracker = usageTracker
    }

    func submit(onShowHistory: () -> Void) {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Add to command history
        commandHistory.add(trimmed)

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
                // Task was cancelled
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
        commandHistory.reset()
    }
}
