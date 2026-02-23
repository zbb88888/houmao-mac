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

    @Published var attachedImages: [AttachedImage] = []
    @Published var lastUserImages: [NSImage]?

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

    func addImage(_ nsImage: NSImage) {
        guard let attached = AttachedImage(image: nsImage) else { return }
        attachedImages.append(attached)
    }

    func removeImage(id: UUID) {
        attachedImages.removeAll { $0.id == id }
    }

    func submit(onShowHistory: () -> Void) {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = !attachedImages.isEmpty
        guard !trimmed.isEmpty || hasImages else { return }

        // Add to command history (only if there's text)
        if !trimmed.isEmpty {
            commandHistory.add(trimmed)
        }

        // Check commands (only when no images attached)
        if !hasImages, let target = commands[trimmed.lowercased()] {
            inputText = ""
            if target == .history { onShowHistory() }
            panel = (panel == target) ? .none : target
            return
        }

        // Normal LLM query
        let question = trimmed.isEmpty ? "Describe this image." : trimmed
        lastUserText = question
        lastLLMReply = nil
        isLoading = true
        panel = .chat

        // Capture images for display and extract base64 for the API call
        let images = attachedImages.map { $0.nsImage }
        let base64s = attachedImages.map { $0.base64JPEG }
        lastUserImages = hasImages ? images : nil
        attachedImages = []
        inputText = ""

        usageTracker?.record(text: question)

        currentTask?.cancel()
        currentTask = Task {
            do {
                let reply = try await llmClient.ask(question: question, imageBase64s: base64s)
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
        lastUserImages = nil
        isLoading = false
        panel = .none
        inputText = ""
        attachedImages = []
        commandHistory.reset()
    }
}
