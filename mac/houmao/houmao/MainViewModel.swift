import SwiftUI
import Observation
import os.log

private let vmLog = Logger(subsystem: "com.houmao", category: "MainViewModel")

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

    /// Conversation history for multi-turn dialogue (max 20 messages).
    private var conversationHistory: [ChatMessage] = []
    private let maxHistoryMessages = 20

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

        // Determine worker and question
        let mention = parseWorkerMention(trimmed)
        let worker: Worker
        let workerName: String?

        if let mention = mention {
            // Has @mention
            guard let w = AppSettings.shared.worker(named: mention.name) else {
                showError("Worker \"\(mention.name)\" not found. Add it in Settings → Workers.")
                return
            }
            worker = w
            workerName = w.name
        } else {
            // No @mention, use first worker
            guard let w = AppSettings.shared.worker(named: nil) else {
                showError("No worker configured. Open Settings (⌘,) to add one.")
                return
            }
            worker = w
            workerName = w.name.isEmpty ? nil : w.name
        }

        // Generate question
        let question: String
        if let mention = mention {
            question = mention.message.isEmpty
                ? (hasAttachments ? "Describe this." : "Hello")
                : mention.message
        } else {
            question = trimmed.isEmpty ? "Describe this." : trimmed
        }

        executeQuery(question: question, worker: worker, workerName: workerName, attachments: attachments)
    }

    private func showError(_ message: String) {
        lastUserText = inputText
        lastLLMReply = "Error: \(message)"
        panel = .chat
        inputText = ""
    }

    private func executeQuery(question: String, worker: Worker, workerName: String?, attachments: [Attachment]) {
        let client = AiTxtClient(baseURL: worker.url, model: worker.model)

        lastUserText = question
        lastLLMReply = nil
        lastWorkerName = workerName
        isLoading = true
        panel = .chat

        let currentAttachments = attachments
        self.attachments = []
        inputText = ""

        usageTracker?.record(text: question)

        currentTask?.cancel()
        currentTask = Task {
            do {
                self.lastLLMReply = ""
                let reply = try await client.askStream(
                    question: question,
                    attachments: currentAttachments,
                    history: conversationHistory
                ) { [weak self] token in
                    Task { @MainActor in
                        self?.lastLLMReply = (self?.lastLLMReply ?? "") + token
                    }
                }
                guard !Task.isCancelled else { return }
                self.lastLLMReply = reply
                // Append to conversation history
                self.conversationHistory.append(ChatMessage(role: "user", content: .text(question)))
                self.conversationHistory.append(ChatMessage(role: "assistant", content: .text(reply)))
                // Trim history to max size
                if self.conversationHistory.count > self.maxHistoryMessages {
                    self.conversationHistory.removeFirst(self.conversationHistory.count - self.maxHistoryMessages)
                }
            } catch is CancellationError {
                vmLog.info("Request cancelled by user")
            } catch {
                vmLog.error("Request failed: \(error.localizedDescription)")
                self.lastLLMReply = "Error: \(error.localizedDescription)"
            }
            self.isLoading = false
        }
    }

    func cancelRequest() {
        currentTask?.cancel()
        currentTask = nil
        isLoading = false
        lastLLMReply = "Request cancelled."
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
        conversationHistory = []
        commandHistory.reset()
    }
}
