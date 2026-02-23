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

    @Published var attachments: [Attachment] = []

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

    func addFile(url: URL) {
        if let nsImage = NSImage(contentsOf: url), let att = Attachment.image(nsImage) {
            attachments.append(att)
        } else if let att = Attachment.audio(url: url) {
            attachments.append(att)
        }
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func submit(onShowHistory: () -> Void) {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = !attachments.isEmpty
        guard !trimmed.isEmpty || hasAttachments else { return }

        if !trimmed.isEmpty {
            commandHistory.add(trimmed)
        }

        // Check commands (only when no media attached)
        if !hasAttachments, let target = commands[trimmed.lowercased()] {
            inputText = ""
            if target == .history { onShowHistory() }
            panel = (panel == target) ? .none : target
            return
        }

        // Normal LLM query
        let question = trimmed.isEmpty ? "Describe this." : trimmed
        lastUserText = question
        lastLLMReply = nil
        isLoading = true
        panel = .chat

        let currentAttachments = attachments
        attachments = []
        inputText = ""

        usageTracker?.record(text: question)

        currentTask?.cancel()
        currentTask = Task {
            do {
                let reply = try await llmClient.ask(question: question, attachments: currentAttachments)
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
        attachments = []
        commandHistory.reset()
    }
}
