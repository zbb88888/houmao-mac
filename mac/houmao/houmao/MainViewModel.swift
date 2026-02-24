import SwiftUI
import Observation

enum Panel: Equatable {
    case none
    case chat
    case history
    case help
}

@MainActor
@Observable
final class MainViewModel {
    var inputText: String = ""
    var lastUserText: String?
    var lastLLMReply: String?
    var isLoading: Bool = false
    var panel: Panel = .none
    var lastWorkerName: String?

    var attachments: [Attachment] = []

    private var currentTask: Task<Void, Never>?
    private(set) var usageTracker: UsageTracker?
    let commandHistory = CommandHistory()

    /// Single-letter commands that toggle panels.
    private let commands: [String: Panel] = [
        "b": .history,
        "h": .help,
    ]

    init(usageTracker: UsageTracker? = nil) {
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
    /// Supports `@worker some question` and `@worker` alone (for attachment-only use).
    private func parseWorkerMention(_ text: String) -> (name: String, message: String)? {
        guard text.hasPrefix("@") else { return nil }
        let parts = text.dropFirst().split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let name = parts.first, !name.isEmpty else { return nil }
        let message = parts.count > 1 ? String(parts[1]) : ""
        return (String(name), message)
    }

    func submit() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAttachments = !attachments.isEmpty
        guard !trimmed.isEmpty || hasAttachments else { return }

        if !trimmed.isEmpty {
            commandHistory.add(trimmed)
        }

        // Check commands (only when no media attached)
        if !hasAttachments, let target = commands[trimmed.lowercased()] {
            inputText = ""
            panel = (panel == target) ? .none : target
            return
        }

        // Check for @worker mention
        var question = trimmed.isEmpty ? "Describe this." : trimmed
        var client = AiTxtClient()
        var workerName: String? = nil

        if let mention = parseWorkerMention(trimmed) {
            if let worker = AppSettings.shared.worker(named: mention.name) {
                question = mention.message.isEmpty
                    ? (hasAttachments ? "Describe this." : "Hello")
                    : mention.message
                client = AiTxtClient(baseURL: worker.url)
                workerName = worker.name
            } else {
                lastUserText = trimmed
                lastLLMReply = "Error: Worker \"\(mention.name)\" not found. Add it in Settings → Workers."
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
