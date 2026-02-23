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
    @Published var lastWorkerName: String?

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

    /// Parse `@workerName message` from input. Returns (workerName, actualMessage) or nil.
    private func parseWorkerMention(_ text: String) -> (name: String, message: String)? {
        guard let match = text.range(of: #"^@(\S+)\s+([\s\S]+)"#, options: .regularExpression) else {
            return nil
        }
        let matched = String(text[match])
        // Extract worker name (after @ until first whitespace)
        let afterAt = matched.dropFirst() // drop @
        guard let spaceIndex = afterAt.firstIndex(where: { $0.isWhitespace }) else { return nil }
        let name = String(afterAt[afterAt.startIndex..<spaceIndex])
        let message = String(afterAt[spaceIndex...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !message.isEmpty else { return nil }
        return (name, message)
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

        // Check for @worker mention
        var question = trimmed.isEmpty ? "Describe this." : trimmed
        var client: LLMClient = llmClient
        var workerName: String? = nil

        if let mention = parseWorkerMention(trimmed) {
            if let worker = AppSettings.shared.worker(named: mention.name) {
                question = mention.message
                client = WorkerClient(baseURL: worker.url)
                workerName = worker.name
            } else {
                // Worker not found — show error
                lastUserText = trimmed
                lastLLMReply = "Error: Worker \"\(mention.name)\" not found. Add it in Settings → Workers."
                lastWorkerName = nil
                isLoading = false
                panel = .chat
                inputText = ""
                return
            }
        }

        lastUserText = question
        lastLLMReply = nil
        lastWorkerName = workerName
        isLoading = true
        panel = .chat

        let currentAttachments = attachments
        attachments = []
        inputText = ""

        usageTracker?.record(text: question)

        currentTask?.cancel()
        currentTask = Task {
            do {
                let reply = try await client.ask(question: question, attachments: currentAttachments)
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
        lastWorkerName = nil
        isLoading = false
        panel = .none
        inputText = ""
        attachments = []
        commandHistory.reset()
    }
}
