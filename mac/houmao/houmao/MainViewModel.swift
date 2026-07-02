import SwiftUI
import AppKit
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

    /// Multi-conversation chat store backing the standalone chat app. Persisted
    /// across sessions (ADR-6, revised) via `ConversationStore`; the minimal box
    /// never clears it.
    let chatStore: ChatStore

    /// Completed one-shot turns in the minimal input box, kept so they can seed
    /// a fresh conversation when the box auto-upgrades to the standalone chat
    /// window. Each entry is a finished `(question, reply, model)` turn.
    private var oneShotTurns: [(user: String, assistant: String, model: String)] = []

    /// The minimal input box is a one-shot Q/A surface. Once the user has had
    /// `autoChatThreshold` turns in it, the next submission auto-upgrades to the
    /// standalone chat window (carrying prior turns over as context).
    private let autoChatThreshold = 3

    /// Registry of `$action` pipeline steps (translate/summarize/save).
    let actionRegistry = ActionRegistry()

    /// Single-letter commands that toggle panels.
    private let commands: [String: Panel] = [
        "b": .history,
        "h": .help,
    ]

    init(usageTracker: UsageTracker? = nil, chatStore: ChatStore? = nil) {
        self.usageTracker = usageTracker
        self.chatStore = chatStore ?? ChatStore()
        registerBuiltinActions()
    }

    /// Register the built-in pipeline actions. `$save` writes Markdown notes to
    /// ~/Documents/houmao/notes on macOS.
    private func registerBuiltinActions() {
        actionRegistry.register(TranslateAction())
        actionRegistry.register(SummarizeAction())
        actionRegistry.register(SaveNoteAction(writer: FileNoteWriter()))
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

        // `/chat` from the minimal box just opens the standalone chat window.
        // The box itself stays a one-shot surface; conversational turns happen
        // in the chat window (whichever window is up is the surface in use).
        if trimmed.lowercased() == "/chat" {
            inputText = ""
            openChatWindow()
            return
        }

        // Check commands (only when no media attached)
        if !hasAttachments, let target = commands[trimmed.lowercased()] {
            inputText = ""
            panel = (panel == target) ? .none : target
            return
        }

        // Determine model and question
        let mention = parseModelMention(trimmed)

        // Pipeline? A `$action` reference (optionally after an @model mention)
        // routes through the pipeline runner instead of a plain query.
        let pipelineBody = mention?.message ?? trimmed
        if let pipeline = PipelineParser.parse(pipelineBody) {
            guard let resolved = AppSettings.shared.resolveModel(named: mention?.name) else {
                showError(mention?.name == nil
                    ? "No provider configured. Open Settings (⌘,) to add one."
                    : "Model \"\(mention!.name)\" not found. Add it in Settings → Providers.")
                return
            }
            executePipeline(pipeline, resolved: resolved)
            return
        }

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

        // Auto-upgrade: the minimal box is a one-shot surface. After enough
        // completed turns, promote the next submission to the standalone chat
        // window, carrying prior text turns over as context. Skipped when files
        // are attached (chat window does not yet relay attachments).
        if attachments.isEmpty && oneShotTurns.count >= autoChatThreshold - 1 {
            autoUpgradeToChat(initialText: question)
            return
        }

        executeQuery(question: question, resolved: resolved, attachments: attachments)
    }

    private func showError(_ message: String) {
        lastUserText = inputText
        lastLLMReply = "Error: \(message)"
        panel = .chat
        inputText = ""
    }

    /// Run a `$action | $action` pipeline. The initial input is the leading
    /// literal segment, or the clipboard contents when the pipeline starts with
    /// an action.
    private func executePipeline(_ pipeline: Pipeline, resolved: ResolvedModel) {
        let fallback = NSPasteboard.general.string(forType: .string) ?? ""
        let label = pipeline.actionNames.map { "$\($0)" }.joined(separator: " | ")

        lastUserText = label
        lastLLMReply = ""
        lastModelName = resolved.provider.name
        isLoading = true
        attachments = []
        inputText = ""
        panel = .chat

        usageTracker?.record(text: label)

        currentTask?.cancel()
        currentTask = Task {
            do {
                let runner = PipelineRunner(registry: actionRegistry)
                let result = try await runner.run(
                    pipeline,
                    fallbackInput: fallback,
                    model: resolved
                ) { [weak self] _, text in
                    self?.lastLLMReply = text
                }
                guard !Task.isCancelled else { return }
                self.lastLLMReply = result
            } catch is CancellationError {
                vmLog.info("Pipeline cancelled by user")
            } catch {
                vmLog.error("Pipeline failed: \(error.localizedDescription)")
                self.lastLLMReply = "Error: \(error.localizedDescription)"
            }
            self.isLoading = false
        }
    }

    /// Open the standalone chat window on the most recent conversation (or a
    /// fresh one). The chat window is a self-contained surface — presenting it
    /// IS the state, so there is no persistent "chat mode" flag to keep in sync.
    /// The persisted conversations are never discarded here.
    func openChatWindow() {
        chatStore.ensureCurrent()
        oneShotTurns.removeAll()
        lastUserText = nil
        lastLLMReply = nil
        lastModelName = nil
        panel = .chat
        NotificationCenter.default.post(name: .houmaoEnterChatWindow, object: nil)
    }

    /// Submit from the standalone chat window. This surface is always a
    /// multi-turn conversation, so route straight to a chat turn — the visible
    /// window is the source of truth, no mode flag required.
    func sendChatTurn() {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        commandHistory.add(trimmed)
        chatStore.ensureCurrent()
        executeChatTurn(trimmed)
    }

    /// Auto-upgrade the one-shot input box into the standalone chat window:
    /// seed a NEW conversation with the completed one-shot turns as context,
    /// open the chat window, then run the triggering submission as its first
    /// chat turn.
    private func autoUpgradeToChat(initialText: String) {
        var seed: [Message] = []
        for turn in oneShotTurns {
            seed.append(Message(role: .user, text: turn.user))
            seed.append(Message(role: .assistant, text: turn.assistant))
        }
        chatStore.newConversation(seeding: seed)
        oneShotTurns.removeAll()
        panel = .chat
        NotificationCenter.default.post(name: .houmaoEnterChatWindow, object: nil)
        executeChatTurn(initialText)
    }

    /// Dismiss the standalone chat window (in-panel ✕ button / title-bar close).
    /// There is no mode flag to clear — hiding the window is the whole
    /// operation; the persisted conversations are untouched.
    func exitChatMode() {
        panel = .none
        inputText = ""
        oneShotTurns.removeAll()
        NotificationCenter.default.post(name: .houmaoExitChatWindow, object: nil)
    }

    /// Map Core chat messages onto the LLM client's wire format.
    private func toChatMessages(_ messages: [Message]) -> [ChatMessage] {
        messages.map { ChatMessage(role: $0.role.rawValue, content: .text($0.text)) }
    }

    /// Run one conversational turn: append the user message, stream the
    /// assistant reply into the session, and feed prior turns back as history.
    private func executeChatTurn(_ text: String) {
        guard let resolved = AppSettings.shared.resolveModel(named: nil) else {
            showError("No provider configured. Open Settings (⌘,) to add one.")
            return
        }

        // Snapshot history BEFORE appending the new user turn.
        let priorHistory = toChatMessages(chatStore.historyMessages)
        chatStore.appendUser(text)
        let assistantID = chatStore.startAssistant(streaming: true)

        lastModelName = resolved.provider.name
        isLoading = true
        inputText = ""
        panel = .chat

        usageTracker?.record(text: text)

        let client = AiTxtClient(
            baseURL: resolved.provider.apiHost,
            model: resolved.model,
            apiKey: resolved.provider.apiKey
        )

        currentTask?.cancel()
        currentTask = Task {
            do {
                let reply = try await client.askStream(
                    question: text,
                    attachments: [],
                    history: priorHistory
                ) { [weak self] token in
                    Task { @MainActor in
                        self?.chatStore.appendToken(assistantID, token)
                    }
                }
                guard !Task.isCancelled else { return }
                chatStore.updateText(assistantID, reply)
            } catch is CancellationError {
                vmLog.info("Chat turn cancelled by user")
            } catch {
                vmLog.error("Chat turn failed: \(error.localizedDescription)")
                chatStore.updateText(assistantID, "Error: \(error.localizedDescription)")
            }
            chatStore.finish(assistantID)
            isLoading = false
        }
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
                self.oneShotTurns.append((user: question, assistant: reply, model: resolved.provider.name))
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
        oneShotTurns.removeAll()
        commandHistory.reset()
    }
}
