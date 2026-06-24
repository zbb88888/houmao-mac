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
    var lastModelName: String?

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

    /// Parse `@model message` from input. Returns (modelName, actualMessage) or nil.
    /// Supports `@model some question` and `@model` alone (for attachment-only use).
    private func parseModelMention(_ text: String) -> (name: String, message: String)? {
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

        // Determine model and question
        let mention = parseModelMention(trimmed)
        let resolved: ResolvedModel

        if let mention = mention {
            // Has @mention → resolve model by name
            guard let r = AppSettings.shared.resolveModel(named: mention.name) else {
                showError("Model \"\(mention.name)\" not found. Add it in Settings → Providers.")
                return
            }
            resolved = r
        } else {
            // No @mention → use default model
            guard let r = AppSettings.shared.resolveModel(named: nil) else {
                showError("No provider configured. Open Settings (⌘,) to add one.")
                return
            }
            resolved = r
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

        executeQuery(question: question, resolved: resolved, attachments: attachments)
    }

    private func showError(_ message: String) {
        lastUserText = inputText
        lastLLMReply = "Error: \(message)"
        panel = .chat
        inputText = ""
    }

    private func executeQuery(question: String, resolved: ResolvedModel, attachments: [Attachment]) {
        let client = AiTxtClient(baseURL: resolved.provider.apiHost, model: resolved.model, apiKey: resolved.provider.apiKey)

        lastUserText = question
        lastLLMReply = nil
        lastModelName = resolved.provider.name
        isLoading = true

        let currentAttachments = attachments
        self.attachments = []
        inputText = ""

        panel = .chat

        usageTracker?.record(text: question)

        currentTask?.cancel()
        currentTask = Task {
            do {
                self.lastLLMReply = ""
                let reply = try await client.askStream(
                    question: question,
                    attachments: currentAttachments,
                    history: []
                ) { [weak self] token in
                    Task { @MainActor in
                        self?.lastLLMReply = (self?.lastLLMReply ?? "") + token
                    }
                }
                guard !Task.isCancelled else { return }
                self.lastLLMReply = reply
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

    func resetInput() {
        currentTask?.cancel()
        lastUserText = nil
        lastLLMReply = nil
        lastModelName = nil
        isLoading = false
        inputText = ""
        attachments = []
        panel = .none
        commandHistory.reset()
    }
}
