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
            // No @mention, use default worker
            guard let w = AppSettings.shared.worker(named: nil) else {
                showError("No default worker configured. Open Settings (⌘,) to add a worker with empty name.")
                return
            }
            worker = w
            workerName = nil
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
        let service = LLMService(baseURL: worker.url)

        lastUserText = question
        lastLLMReply = ""
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
                let stream = service.stream(
                    question: question,
                    model: worker.model,
                    attachments: currentAttachments
                )

                for try await delta in stream {
                    guard !Task.isCancelled else { break }
                    if self.isLoading {
                        self.isLoading = false
                    }
                    self.lastLLMReply = (self.lastLLMReply ?? "") + delta
                }

                // Strip thinking process: drop everything up to and including the last </think>.
                if let reply = self.lastLLMReply {
                    let stripped = reply
                        .replacingOccurrences(of: "^[\\s\\S]*</think>", with: "", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !stripped.isEmpty {
                        self.lastLLMReply = stripped
                    }
                }
            } catch is CancellationError {
                // Task was cancelled
            } catch {
                if (self.lastLLMReply ?? "").isEmpty {
                    self.lastLLMReply = "Error: \(error.localizedDescription)"
                } else {
                    self.lastLLMReply = (self.lastLLMReply ?? "") + "\n\n[Error: \(error.localizedDescription)]"
                }
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
