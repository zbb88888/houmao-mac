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

    /// The current model's context window (tokens), or 0 when unknown. Resolved
    /// from the provider backing `lastModelName` (else the default provider).
    var contextWindowTokens: Int {
        AppSettings.shared.resolveModel(named: lastModelName)?.provider.contextTokens ?? 0
    }

    /// Rough token estimate of the current conversation (~3 chars/token, matching
    /// the analyzer's budget heuristic). Used only for the status-bar ring.
    var contextUsedTokens: Int {
        chatStore.messages.reduce(0) { $0 + $1.text.count / 3 }
    }

    /// Best-effort populate any missing context windows so the ring has a value
    /// without the user visiting Settings. Fire-and-forget.
    func ensureContextWindows() {
        Task { await AppSettings.shared.detectMissingContextWindows() }
    }

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

    /// Per assistant-bubble "深入" context for mail analyses: the original mail
    /// prompt (with bodies) that seeded the bubble, so a follow-up turn can go
    /// deeper using the prior analysis as context (keyed by assistant msg id).
    private var mailDeepen: [UUID: String] = [:]

    /// When set, the chat view parks this bubble at the TOP of the viewport on
    /// the next message-count change / window show, instead of scrolling to the
    /// bottom. Mail analysis sets it to the new "分析邮件：…" header so previous
    /// history is pushed above the fold and the streamed reply fills the space
    /// below. The chat view clears it once applied.
    var topAnchorMessageID: UUID?

    /// The minimal input box is a one-shot Q/A surface. Once the user has had
    /// `autoChatThreshold` turns in it, the next submission auto-upgrades to the
    /// standalone chat window (carrying prior turns over as context).
    private let autoChatThreshold = 3

    /// Registry of `$action` pipeline steps (translate/summarize/save).
    let actionRegistry = ActionRegistry()

    /// Single-letter commands that toggle panels. Slash aliases (`/h`, `/b`)
    /// are accepted too, for consistency with `/chat` `/issue` `/pr`.
    private let commands: [String: Panel] = [
        "b": .history,
        "h": .help,
        "/b": .history,
        "/h": .help,
        "/help": .help,
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

        // Slash "/tool" commands (`/chat` `/mail` `/issue` `/pr`) are dispatched
        // through the single shared router so the minimal box and the chat window
        // always support the exact same tool set (see docs: 命令一致性).
        if handleToolCommand(trimmed) { return }

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
        // Same shared "/tool" router as the minimal box, so both surfaces expose
        // an identical tool set (see docs: 命令一致性).
        if handleToolCommand(trimmed) { return }
        // `/h` shows the brief help doc directly (never sent to the LLM);
        // `/h <question>` sends the question + detailed doc to the LLM.
        if isHelpCommand(trimmed) {
            appendIssueTurn(command: trimmed, reply: Self.helpBrief)
            return
        }
        if let q = helpQuestion(trimmed) {
            chatStore.ensureCurrent()
            executeChatTurn(q, context: Self.helpDetailed)
            return
        }
        chatStore.ensureCurrent()
        executeChatTurn(trimmed)
    }

    /// Single source of truth for slash "/tool" command dispatch, shared by every
    /// input surface (the minimal box's `submit()` and the chat window's
    /// `sendChatTurn()`). Adding a tool here makes it available on both surfaces
    /// at once — surfaces must never route these commands independently, or the
    /// tool set drifts (e.g. `/mail` once worked in the box but not in chat).
    ///
    /// Returns true if `trimmed` was a recognized tool command and consumed.
    /// Surface-specific behavior (one-shot query vs multi-turn chat, and how help
    /// is rendered) stays in the respective caller; only the tool set is shared.
    @discardableResult
    func handleToolCommand(_ trimmed: String) -> Bool {
        switch trimmed.lowercased() {
        case "/chat":
            inputText = ""
            openChatWindow()
            return true
        case "/mail":
            inputText = ""
            NotificationCenter.default.post(name: .houmaoEnterMailWindow, object: nil)
            return true
        default:
            break
        }
        // `/issue <url>` / `/pr <url>` analyze a GitHub issue or PR against a
        // local repo (external `ghia`), rendered as a conversation in the chat
        // window. `/pr` additionally reviews the diff.
        if let mode = analysisMode(trimmed) {
            inputText = ""
            analyzeCommand(trimmed, mode: mode)
            return true
        }
        return false
    }

    /// True for the bare help command (no follow-up question).
    private func isHelpCommand(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower == "/h" || lower == "/help"
    }

    /// For `/h <question>`, returns the trimmed question; nil otherwise.
    private func helpQuestion(_ text: String) -> String? {
        for prefix in ["/h ", "/help "] where text.lowercased().hasPrefix(prefix) {
            let q = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            return q.isEmpty ? nil : q
        }
        return nil
    }

    /// Brief help shown (as Markdown) directly in the chat for a bare `/h`.
    /// Keep in sync with the minimal box's Help panel (`MainView.helpContent`).
    static let helpBrief = """
    ## 命令
    - `/chat` — 打开/切换多轮聊天窗口
    - `/mail` — 打开 Gmail 清理面板（聚类 + 批量移废纸篓）
    - `/issue <url>` — 用本地代码分析 GitHub issue
    - `/pr <url>` — 用本地代码 review GitHub PR diff
    - `/h` — 显示本帮助；`/h <问题>` — 结合文档让 AI 解答如何操作
    - `@name msg` — 指定 provider 别名或模型名

    ## 快捷键
    - 双击 Option — 显示/隐藏窗口
    - Esc / ⌘W — 隐藏窗口
    - ⌘B — 切换用量历史 · ⌘L — 清空历史

    ## 设置（⌘,）
    - **code dir** — 本地仓库根目录；`/issue`、`/pr` 在 `<code dir>/<repo>` 定位
    - **Copy on Selection** — 选中即复制（需辅助功能权限）
    - **Providers** — 添加 OpenAI 兼容 provider；第一个为默认
    """

    /// Detailed doc sent to the LLM as context for `/h <question>`, so it can
    /// give concrete operating steps. Not shown verbatim in the chat.
    static let helpDetailed = """
    # houmao 使用详解

    ## 命令
    - `/chat`：打开多轮聊天窗口。最小输入框是一次性问答，多轮对话在聊天窗口进行。
    - `/issue <github-issue-url>`：调用本地 ghia，用本地仓库代码分析该 issue。需先设置 code dir，且 `<code dir>/<repo>` 存在该仓库克隆。
    - `/pr <github-pr-url>`：同上，额外对 PR diff 做四阶段漏斗深度 review。
    - `/h`：显示简要帮助；`/h <问题>`：结合本文档让 AI 解答如何操作。
    - `@name <消息>`：临时指定 provider 别名或模型名。

    ## 快捷键
    - 双击 Option：显示/隐藏窗口
    - Esc / ⌘W：隐藏窗口
    - ⌘B：切换用量历史
    - ⌘L：清空历史

    ## 设置（⌘,）
    ### code dir
    本地仓库根目录。设置后 `/issue`、`/pr` 会在 `<code dir>/<repo>` 或 `<code dir>/<owner>/<repo>` 定位仓库。在设置面板点 code dir 行的铅笔手动填写，或点文件夹图标选择目录。

    ### Copy on Selection（选中即复制）
    开启后，在任意 app 选中文本会自动复制到剪贴板。需要「辅助功能」权限：系统设置 → 隐私与安全性 → 辅助功能 → 勾选 houmao。设置面板里有该开关；若权限未授予，开关会提示去授权。

    ### Providers
    添加 OpenAI 兼容的 provider（Name、URL、Models、可选 API Key）。列表第一个为默认。上下文窗口会自动探测（vLLM 走 `/v1/models` 的 `max_model_len`，LM Studio 走 `/api/v0/models` 的 `loaded_context_length`）。
    """


    // MARK: - /issue and /pr commands

    /// Returns the ghia analysis mode for a command line, or nil if it isn't one.
    private func analysisMode(_ text: String) -> String? {
        let lower = text.lowercased()
        if lower == "/issue" || lower.hasPrefix("/issue ") { return "issue" }
        if lower == "/pr" || lower.hasPrefix("/pr ") { return "pr" }
        return nil
    }

    /// Parse `/issue <url>` or `/pr <url>` and analyze it against the local
    /// repository (auto-located under the configured repos root) via the
    /// external `ghia` tool, rendered as a chat turn. `/pr` reviews the diff.
    func analyzeCommand(_ text: String, mode: String) {
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        let cmd = tokens.first ?? "/issue"
        guard tokens.count >= 2 else {
            let kind = mode == "pr" ? "PR" : "issue"
            appendIssueTurn(command: text, reply: "用法：\(cmd) <github-\(kind)-URL>")
            return
        }
        let url = tokens[1]

        guard let (owner, repo) = parseGitHubOwnerRepo(url) else {
            appendIssueTurn(command: text, reply: "无法识别 issue/PR URL：\(url)")
            return
        }

        guard let repoPath = AppSettings.shared.resolveRepoPath(owner: owner, repo: repo) else {
            let root = AppSettings.shared.reposRoot.trimmingCharacters(in: .whitespaces)
            let reply: String
            if root.isEmpty {
                reply = "尚未设置 code dir。请在设置（⌘,）配置 code dir（存放本地仓库的根目录），之后 /issue、/pr 会自动在 <code dir>/\(repo) 定位。"
            } else {
                reply = "code dir 已设为「\(root)」，但其下没找到仓库 \(repo)。请确认已 clone 到 \(root)/\(repo)（或 \(root)/\(owner)/\(repo)）。"
            }
            appendIssueTurn(command: text, reply: reply)
            return
        }

        guard let resolved = AppSettings.shared.resolveModel(named: nil) else {
            appendIssueTurn(command: text, reply: "未配置 provider，请先在设置（⌘,）中添加。")
            return
        }

        // Each analysis starts a fresh conversation: different PRs/issues use a
        // brand-new session so context stays small (local LLM window is limited)
        // and follow-up chat only carries this analysis.
        chatStore.newConversation()
        panel = .chat
        NotificationCenter.default.post(name: .houmaoEnterChatWindow, object: nil)

        chatStore.appendUser(text)
        let assistantID = chatStore.startAssistant(streaming: true)
        lastModelName = resolved.provider.name
        isLoading = true
        inputText = ""

        let analyzer = IssueAnalyzer(config: .init(
            binaryPath: IssueAnalyzer.defaultBinaryPath,
            apiKey: resolved.provider.apiKey,
            baseURL: resolved.provider.apiHost + "/v1",
            model: resolved.model,
            contextTokens: resolved.provider.contextTokens
        ))

        currentTask?.cancel()
        currentTask = Task {
            await streamGhia(analyzer, url: url, repoPath: repoPath, mode: mode, into: assistantID)
            isLoading = false
        }
    }

    /// Stream a `ghia` analysis into an assistant message: content → tokens,
    /// ending with `finish`. Shared by `/pr`·`/issue` commands and the mail
    /// task-bubble flow. Honors the calling `Task`'s cancellation.
    ///
    /// This is a single, append-only pass: whatever has been shown stays put —
    /// the bubble is never cleared or rolled back. Transient failures are
    /// retried *inside* `ghia` at the stage that failed (the funnel resumes
    /// there instead of restarting from stage one), so retries are invisible
    /// here. If `ghia` still fails, the error is appended after the existing
    /// content rather than replacing it.
    private func streamGhia(
        _ analyzer: IssueAnalyzer,
        url: String,
        repoPath: String,
        mode: String,
        into assistantID: UUID
    ) async {
        do {
            for try await event in analyzer.stream(url: url, repoPath: repoPath, mode: mode) {
                if Task.isCancelled { break }
                switch event {
                case .progress: break
                case .content(let c): chatStore.appendToken(assistantID, c)
                }
            }
            chatStore.finish(assistantID)
            if !Task.isCancelled {
                let kind = mode == "pr" ? "PR 深度 review" : "Issue 分析"
                AppDelegate.shared?.notifyTaskDone(title: "\(kind)已完成", body: url)
            }
        } catch is CancellationError {
            chatStore.finish(assistantID)
        } catch {
            chatStore.appendToken(assistantID, "\n\n分析中断：\(error.localizedDescription)\n可再次执行该命令重试。")
            chatStore.finish(assistantID)
        }
    }

    /// Discard the whole conversation and start fresh (the chat “renew” button).
    func renewChat() {
        currentTask?.cancel()
        isLoading = false
        inputText = ""
        mailDeepen.removeAll()
        topAnchorMessageID = nil
        chatStore.reset()
    }

    /// Whether an assistant bubble is a mail analysis that can be deepened.
    func canDeepenMail(_ id: UUID) -> Bool { mailDeepen[id] != nil }

    /// Follow-up “深入”: continue an existing mail-analysis bubble with a
    /// “go deeper” prompt instead of re-running it (which just reproduced the
    /// same content). The original mail context and the prior analysis are
    /// passed as history so the model builds on it rather than repeating; the
    /// elaboration streams as a new turn, itself deepenable.
    func deepenMail(_ id: UUID) {
        guard let source = mailDeepen[id],
              let prior = chatStore.messages.first(where: { $0.id == id })?.text,
              !prior.isEmpty,
              let resolved = AppSettings.shared.resolveModel(named: nil) else { return }
        let userID = chatStore.appendUser("进一步深入分析")
        let assistantID = chatStore.startAssistant(streaming: true)
        lastModelName = resolved.provider.name
        // Chainable: the elaboration can itself be deepened again.
        mailDeepen[assistantID] = source
        topAnchorMessageID = userID
        NotificationCenter.default.post(name: .houmaoEnterChatWindow, object: nil)

        let history = [
            ChatMessage(role: "user", content: .text(source)),
            ChatMessage(role: "assistant", content: .text(prior)),
        ]
        let deepenPrompt = "请在上一版分析的基础上进一步深入：展开之前一带而过或未覆盖的关键细节、潜在风险与边界情况，并给出更具体、可执行的下一步建议。不要重复已经说过的内容，用中文。"
        let client = AiTxtClient(baseURL: resolved.provider.apiHost, model: resolved.model, apiKey: resolved.provider.apiKey)
        Task {
            do {
                _ = try await client.askStream(question: deepenPrompt, attachments: [], history: history) { [weak self] token in
                    Task { @MainActor in self?.chatStore.appendToken(assistantID, token) }
                }
            } catch {
                chatStore.appendToken(assistantID, "\n\n深入分析失败：\(error.localizedDescription)")
            }
            chatStore.finish(assistantID)
        }
    }

    /// Render a `/issue` command and an immediate (non-LLM) reply as one chat
    /// turn, e.g. usage or configuration errors.
    private func appendIssueTurn(command: String, reply: String) {
        chatStore.ensureCurrent()
        panel = .chat
        NotificationCenter.default.post(name: .houmaoEnterChatWindow, object: nil)
        chatStore.appendUser(command)
        let id = chatStore.startAssistant(streaming: false)
        chatStore.updateText(id, reply)
        chatStore.finish(id)
        inputText = ""
    }

    /// Extract (owner, repo) from a GitHub issue/PR URL; nil if it doesn't match.
    private func parseGitHubOwnerRepo(_ url: String) -> (owner: String, repo: String)? {
        let pattern = #"github\.com/([^/]+)/([^/]+)/(?:issues|pull)/\d+"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let ownerRange = Range(m.range(at: 1), in: url),
              let repoRange = Range(m.range(at: 2), in: url) else {
            return nil
        }
        return (String(url[ownerRange]), String(url[repoRange]))
    }

    /// Analyze mail as a **task bubble** in the chat window's current
    /// conversation: a user bubble "分析邮件：<标题>" plus a streamed assistant
    /// reply. `mails` is a whole cluster ordered oldest→newest (a "thread"); a
    /// GitHub PR/issue link runs `ghia` against the local repo, otherwise the
    /// thread gets an LLM time-line summary.
    ///
    /// Brings the chat window to the front and parks this analysis's header
    /// bubble ("分析邮件：…") at the top of the viewport, so prior history scrolls
    /// above the fold and the streamed reply has the full window below it. The
    /// mail window is left untouched (it simply drops behind the chat window).
    func analyzeMailForChat(mails: [MailMessageDetail], github: (url: String, mode: String)?) {
        guard let resolved = AppSettings.shared.resolveModel(named: nil) else {
            showError("No provider configured. Open Settings (⌘,) to add one.")
            return
        }
        guard let first = mails.first else { return }
        let subject = first.subject.isEmpty ? "(无主题)" : first.subject
        chatStore.ensureCurrent()
        let userID: UUID
        if mails.count == 1 {
            userID = chatStore.appendUser("分析邮件：\(subject)")
        } else {
            // List every message (numbered, time order) so the user sees exactly
            // which mails go into this one combined analysis.
            let list = mails.enumerated()
                .map { "\($0.offset + 1). \($0.element.subject.isEmpty ? "(无主题)" : $0.element.subject)" }
                .joined(separator: "\n")
            userID = chatStore.appendUser("分析邮件（共 \(mails.count) 封，按时间从早到晚）：\n\(list)")
        }
        let assistantID = chatStore.startAssistant(streaming: true)
        lastModelName = resolved.provider.name
        vmLog.info("mailAI: bubbles created mails=\(mails.count) github=\(github != nil) conv=\(self.chatStore.conversations.count) msgs=\(self.chatStore.messages.count) currentSet=\(self.chatStore.currentID != nil)")
        // Register the mail context so this bubble can later be “深入”-ed
        // (a follow-up turn that builds on the analysis instead of re-running it).
        mailDeepen[assistantID] = Self.mailThreadPrompt(mails)
        // Park this analysis's header bubble at the top of the chat viewport
        // (pushing prior history above the fold, leaving space for the reply)
        // and bring the chat window to the front.
        topAnchorMessageID = userID
        NotificationCenter.default.post(name: .houmaoEnterChatWindow, object: nil)

        // A GitHub PR/issue link → analyze against the local repo via ghia.
        if let github, let (owner, repo) = parseGitHubOwnerRepo(github.url) {
            guard let repoPath = AppSettings.shared.resolveRepoPath(owner: owner, repo: repo) else {
                let root = AppSettings.shared.reposRoot.trimmingCharacters(in: .whitespaces)
                let reply = root.isEmpty
                    ? "尚未设置 code dir，无法分析 \(repo)。请在设置（⌘,）配置 code dir。"
                    : "code dir「\(root)」下没找到仓库 \(repo)。请确认已 clone 到 \(root)/\(repo)。"
                chatStore.updateText(assistantID, reply)
                chatStore.finish(assistantID)
                return
            }
            let analyzer = IssueAnalyzer(config: .init(
                binaryPath: IssueAnalyzer.defaultBinaryPath,
                apiKey: resolved.provider.apiKey,
                baseURL: resolved.provider.apiHost + "/v1",
                model: resolved.model,
                contextTokens: resolved.provider.contextTokens
            ))
            // Independent task (not `currentTask`): analyzing several mails
            // back-to-back must not cancel each other's in-flight analysis.
            Task { await streamGhia(analyzer, url: github.url, repoPath: repoPath, mode: github.mode, into: assistantID) }
            return
        }

        // Otherwise → LLM summary / time-line analysis of the thread.
        let prompt = Self.mailThreadPrompt(mails)
        let client = AiTxtClient(baseURL: resolved.provider.apiHost, model: resolved.model, apiKey: resolved.provider.apiKey)
        Task {
            do {
                _ = try await client.askStream(question: prompt, attachments: [], history: []) { [weak self] token in
                    Task { @MainActor in self?.chatStore.appendToken(assistantID, token) }
                }
            } catch {
                chatStore.appendToken(assistantID, "\n\n分析失败：\(error.localizedDescription)")
            }
            chatStore.finish(assistantID)
            vmLog.info("mailAI: stream finished conv=\(self.chatStore.conversations.count) msgs=\(self.chatStore.messages.count) currentSet=\(self.chatStore.currentID != nil)")
        }
    }

    /// Build the LLM prompt for a mail thread (one or more messages already
    /// ordered oldest→newest).
    private static func mailThreadPrompt(_ mails: [MailMessageDetail]) -> String {
        if mails.count == 1 {
            let m = mails[0]
            var header = "发件人：\(m.from)\n"
            if !m.to.isEmpty { header += "收件人：\(m.to)\n" }
            if !m.date.isEmpty { header += "时间：\(m.date)\n" }
            header += "主题：\(m.subject.isEmpty ? "(无主题)" : m.subject)"
            return """
            请阅读下面这封邮件，用中文快速给出：
            1) 一句话摘要；
            2) 3-5 条核心要点（要点式）；
            3) 是否需要我处理或回复；若需要，给出建议动作。
            只输出结论，不要复述原文。

            \(header)
            正文：
            \(m.body)
            """
        }
        var thread = ""
        for (index, m) in mails.enumerated() {
            thread += "【第 \(index + 1) 封】"
            if !m.date.isEmpty { thread += "时间：\(m.date)  " }
            thread += "发件人：\(m.from)\n主题：\(m.subject.isEmpty ? "(无主题)" : m.subject)\n正文：\n\(m.body)\n\n---\n\n"
        }
        return """
        下面是同一主题下的 \(mails.count) 封邮件，已按时间从早到晚排列。请用中文：
        1) 概述这组邮件讲了什么、事情如何随时间推进；
        2) 提炼关键结论 / 决定 / 待办；
        3) 是否需要我处理或回复；若需要，给出建议动作。
        只输出结论，不要逐封复述。

        \(thread)
        """
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
        currentTask?.cancel()
        panel = .none
        inputText = ""
        oneShotTurns.removeAll()
        NotificationCenter.default.post(name: .houmaoExitChatWindow, object: nil)
    }

    /// Map Core chat messages onto the LLM client's wire format.
    private func toChatMessages(_ messages: [Message]) -> [ChatMessage] {
        messages.map { ChatMessage(role: $0.role.rawValue, content: .text($0.text)) }
    }

    /// Prior one-shot turns as LLM history, so the minimal box (临时对话框) is a
    /// real ongoing conversation with memory while it stays open.
    private func oneShotHistory() -> [ChatMessage] {
        var history: [ChatMessage] = []
        for turn in oneShotTurns {
            history.append(ChatMessage(role: "user", content: .text(turn.user)))
            history.append(ChatMessage(role: "assistant", content: .text(turn.assistant)))
        }
        return history
    }

    /// Run one conversational turn: append the user message, stream the
    /// assistant reply into the session, and feed prior turns back as history.
    private func executeChatTurn(_ text: String, context: String? = nil) {
        // A normal chat turn ends any mail-analysis top-pin: drop the reserved
        // bottom spacer and restore ordinary bottom-follow.
        topAnchorMessageID = nil
        // Support `@name msg` to pick a provider/model, just like the minimal box.
        let mention = parseModelMention(text)
        let question = (mention?.message.isEmpty == false) ? mention!.message : text

        guard let resolved = AppSettings.shared.resolveModel(named: mention?.name) else {
            let msg = mention?.name == nil
                ? "No provider configured. Open Settings (⌘,) to add one."
                : "Model \"\(mention!.name)\" not found. Add it in Settings → Providers."
            chatStore.appendUser(question)
            let id = chatStore.startAssistant(streaming: false)
            chatStore.updateText(id, msg)
            chatStore.finish(id)
            inputText = ""
            return
        }

        // The bubble shows the user's question; `context` (e.g. the help doc) is
        // prepended only to what's sent to the LLM, not displayed.
        let sentQuestion: String
        if let context {
            sentQuestion = "参考以下 houmao 使用文档回答用户问题，给出具体、可操作的步骤。\n\n<文档>\n\(context)\n</文档>\n\n用户问题：\(question)"
        } else {
            sentQuestion = question
        }

        // Snapshot history BEFORE appending the new user turn.
        let priorHistory = toChatMessages(chatStore.historyMessages)
        chatStore.appendUser(question)
        let assistantID = chatStore.startAssistant(streaming: true)

        lastModelName = resolved.provider.name
        isLoading = true
        inputText = ""
        panel = .chat

        usageTracker?.record(text: question)

        let client = AiTxtClient(
            baseURL: resolved.provider.apiHost,
            model: resolved.model,
            apiKey: resolved.provider.apiKey,
            systemPrompt: AiTxtClient.chatSystemPrompt
        )

        currentTask?.cancel()
        currentTask = Task {
            do {
                let reply = try await client.askStream(
                    question: sentQuestion,
                    attachments: [],
                    // 聊天框：多轮对话，回放全部历史（见 docs/ui-design.md §4）。
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

    /// One-shot query from the 临时对话框 (minimal input box). While the box
    /// stays open it is a real ongoing conversation: prior turns are replayed as
    /// history so the model has memory. The turns also seed a fresh chat
    /// conversation if the box later upgrades to the chat window.
    private func executeQuery(question: String, resolved: ResolvedModel, attachments: [Attachment]) {
        let client = AiTxtClient(baseURL: resolved.provider.apiHost, model: resolved.model, apiKey: resolved.provider.apiKey, systemPrompt: AiTxtClient.chatSystemPrompt)

        lastUserText = question
        lastLLMReply = nil
        lastModelName = resolved.provider.name
        isLoading = true

        let currentAttachments = attachments
        self.attachments = []
        inputText = ""

        panel = .chat

        usageTracker?.record(text: question)

        let history = oneShotHistory()
        currentTask?.cancel()
        currentTask = Task {
            do {
                self.lastLLMReply = ""
                let reply = try await client.askStream(
                    question: question,
                    attachments: currentAttachments,
                    // Replay prior one-shot turns so the open box keeps context.
                    history: history
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
