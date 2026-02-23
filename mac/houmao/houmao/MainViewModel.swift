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

    @Published var attachedAudios: [AttachedAudio] = []
    @Published var lastUserAudios: [(name: String, duration: TimeInterval)]?

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

    func addAudio(url: URL) {
        guard let attached = AttachedAudio(url: url) else { return }
        attachedAudios.append(attached)
    }

    func removeAudio(id: UUID) {
        attachedAudios.removeAll { $0.id == id }
    }

    func submit(onShowHistory: () -> Void) {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasImages = !attachedImages.isEmpty
        let hasAudios = !attachedAudios.isEmpty
        guard !trimmed.isEmpty || hasImages || hasAudios else { return }

        // Add to command history (only if there's text)
        if !trimmed.isEmpty {
            commandHistory.add(trimmed)
        }

        // Check commands (only when no media attached)
        if !hasImages && !hasAudios, let target = commands[trimmed.lowercased()] {
            inputText = ""
            if target == .history { onShowHistory() }
            panel = (panel == target) ? .none : target
            return
        }

        // Normal LLM query
        let question: String
        if trimmed.isEmpty {
            question = hasAudios ? "Describe this audio." : "Describe this image."
        } else {
            question = trimmed
        }
        lastUserText = question
        lastLLMReply = nil
        isLoading = true
        panel = .chat

        // Capture images for display and extract base64 for the API call
        let images = attachedImages.map { $0.nsImage }
        let base64s = attachedImages.map { $0.base64JPEG }
        lastUserImages = hasImages ? images : nil

        // Capture audios for display and extract data for the API call
        let audioInfos = attachedAudios.map { (name: $0.fileName, duration: $0.duration) }
        let audioParts = attachedAudios.map { (data: $0.base64Data, format: $0.format) }
        lastUserAudios = hasAudios ? audioInfos : nil

        attachedImages = []
        attachedAudios = []
        inputText = ""

        usageTracker?.record(text: question)

        currentTask?.cancel()
        currentTask = Task {
            do {
                let reply = try await llmClient.ask(question: question, imageBase64s: base64s, audioBase64s: audioParts)
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
        lastUserAudios = nil
        isLoading = false
        panel = .none
        inputText = ""
        attachedImages = []
        attachedAudios = []
        commandHistory.reset()
    }
}
