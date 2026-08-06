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

    /// Per assistant-bubble key web link, shown as a clickable chip in the
    /// reply bubble (opens in the default browser). Format-matched from the
    /// source (mail body's last link / the analyzed PR·issue URL), no LLM.
    private var replyLinks: [UUID: URL] = [:]

    /// The key web link to show in an assistant bubble, if any.
    func replyLink(for id: UUID) -> URL? { replyLinks[id] }

    /// When set, the chat view parks this bubble at the TOP of the viewport on
    /// the next message-count change / window show, instead of scrolling to the
    /// bottom. Mail analysis sets it to the new "分析邮件：…" header so previous
    /// history is pushed above the fold and the streamed reply fills the space
    /// below. The chat view clears it once applied.
    var topAnchorMessageID: UUID?

    /// When set, the chat is in "document edit" mode: it is bound to a source
    /// document; every first turn is primed with the document, and the chat's
    /// "保存到原文档" button writes the AI's fixed full text back via `onSave`.
    var documentBinding: ChatDocumentBinding?

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
        case "/do":
            inputText = ""
            NotificationCenter.default.post(name: .houmaoEnterDoWindow, object: nil)
            return true
        case "/goal":
            inputText = ""
            NotificationCenter.default.post(name: .houmaoEnterGoalsWindow, object: nil)
            return true
        case "/worklog":
            inputText = ""
            NotificationCenter.default.post(name: .houmaoEnterWorkLogWindow, object: nil)
            return true
        case "/agent":
            inputText = ""
            NotificationCenter.default.post(name: .houmaoEnterAgentWindow, object: nil)
            return true
        case "/ai":
            inputText = ""
            NotificationCenter.default.post(name: .houmaoEnterAIWindow, object: nil)
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
    - `/do` — 打开 Do 待办面板（工作/生活 两页，主题可增删）
    - `/worklog` — 打开工作量总结面板（按 from 逐个总结 PR/issue，再按季度/半年/全年做 OKR 归纳）
    - `/agent` — 打开动态收件箱（主观能动性：后台监听请求我 review 的 PR / 指派给我的 Issue）
    - `/ai` — 打开 AI 助手（用自然语言描述意图，模型自己决定调用哪些工具后作答）
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

    /// Refresh the chat for a fresh single-item analysis: cancel any in-flight
    /// analysis and open a new conversation so both the visible history and the
    /// LLM context are cleared — only the current item's analysis remains.
    /// Shared by the mail / PR·issue / markdown-fix single-item flows so they
    /// all behave the same way.
    private func beginAnalysisSession() {
        currentTask?.cancel()
        mailDeepen.removeAll()
        replyLinks.removeAll()
        topAnchorMessageID = nil
        oneShotTurns.removeAll()
        chatStore.newConversation()
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
        beginAnalysisSession()
        panel = .chat
        NotificationCenter.default.post(name: .houmaoEnterChatWindow, object: nil)

        chatStore.appendUser(text)
        let assistantID = chatStore.startAssistant(streaming: true)
        if let u = URL(string: url) { replyLinks[assistantID] = u }
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
        replyLinks.removeAll()
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
        if let link = replyLinks[id] { replyLinks[assistantID] = link }
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
        guard !mails.isEmpty else { return }
        beginAnalysisSession()
        // A cluster is one thread: collapse identical titles (ignoring Re:/Fwd:
        // prefixes) to the single cluster title instead of repeating it per mail.
        let titles = Self.uniqueCleanSubjects(mails)
        let userID: UUID
        if titles.count == 1 {
            userID = mails.count == 1
                ? chatStore.appendUser("分析邮件：\(titles[0])")
                : chatStore.appendUser("分析邮件（共 \(mails.count) 封）：\(titles[0])")
        } else {
            // Mixed titles: list the distinct ones (numbered, first-seen order).
            let list = titles.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
            userID = chatStore.appendUser("分析邮件（共 \(mails.count) 封，按时间从早到晚）：\n\(list)")
        }
        let assistantID = chatStore.startAssistant(streaming: true)
        lastModelName = resolved.provider.name
        vmLog.info("mailAI: bubbles created mails=\(mails.count) github=\(github != nil) conv=\(self.chatStore.conversations.count) msgs=\(self.chatStore.messages.count) currentSet=\(self.chatStore.currentID != nil)")
        // Register the mail context so this bubble can later be “深入”-ed
        // (a follow-up turn that builds on the analysis instead of re-running it).
        mailDeepen[assistantID] = Self.mailThreadPrompt(mails)
        if let link = Self.lastMailLink(in: mails) { replyLinks[assistantID] = link }
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
            // Each mail analysis refreshes the chat (see beginAnalysisSession),
            // so a newer analysis supersedes this one via currentTask.
            currentTask = Task { await streamGhia(analyzer, url: github.url, repoPath: repoPath, mode: github.mode, into: assistantID) }
            return
        }

        // Otherwise → LLM summary / time-line analysis of the thread.
        let prompt = Self.mailThreadPrompt(mails)
        let client = AiTxtClient(baseURL: resolved.provider.apiHost, model: resolved.model, apiKey: resolved.provider.apiKey)
        currentTask = Task {
            do {
                _ = try await client.askStream(question: prompt, attachments: [], history: []) { [weak self] token in
                    Task { @MainActor in self?.chatStore.appendToken(assistantID, token) }
                }
            } catch is CancellationError {
                // Superseded by a newer analysis; leave the abandoned bubble as-is.
            } catch {
                chatStore.appendToken(assistantID, "\n\n分析失败：\(error.localizedDescription)")
            }
            chatStore.finish(assistantID)
            vmLog.info("mailAI: stream finished conv=\(self.chatStore.conversations.count) msgs=\(self.chatStore.messages.count) currentSet=\(self.chatStore.currentID != nil)")
        }
    }

    /// Send the editor's whole Markdown document to the chat as an auto-fix
    /// request: a short labeled user bubble plus a streamed reply containing the
    /// fixed document, which the user copies back into the editor. Uses a fixed
    /// "repair Markdown format" prompt (structural fixes the static linter leaves
    /// to the AI).
    func fixMarkdownForChat(_ markdown: String) {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let resolved = AppSettings.shared.resolveModel(named: nil) else {
            showError("No provider configured. Open Settings (⌘,) to add one.")
            return
        }
        beginAnalysisSession()
        let userID = chatStore.appendUser("修复 Markdown 格式")
        let assistantID = chatStore.startAssistant(streaming: true)
        lastModelName = resolved.provider.name
        topAnchorMessageID = userID
        NotificationCenter.default.post(name: .houmaoEnterChatWindow, object: nil)

        let prompt = Self.markdownFixPrompt(markdown)
        let client = AiTxtClient(
            baseURL: resolved.provider.apiHost,
            model: resolved.model,
            apiKey: resolved.provider.apiKey
        )
        currentTask = Task {
            do {
                let reply = try await client.askStream(question: prompt, attachments: [], history: []) { [weak self] token in
                    Task { @MainActor in self?.chatStore.appendToken(assistantID, token) }
                }
                guard !Task.isCancelled else { return }
                chatStore.updateText(assistantID, reply)
            } catch is CancellationError {
                vmLog.info("Markdown fix cancelled by user")
            } catch {
                vmLog.error("Markdown fix failed: \(error.localizedDescription)")
                chatStore.updateText(assistantID, "Error: \(error.localizedDescription)")
            }
            chatStore.finish(assistantID)
        }
    }

    // MARK: - Document-bound chat (edit a source document via chat)

    /// Binds the chat to a source document while in "document edit" mode.
    struct ChatDocumentBinding {
        let title: String
        var markdown: String
        let onSave: (String) -> Void
    }

    /// Open the standalone chat bound to a source document: a fresh conversation
    /// primed (on its first turn) with the document, whose "保存到原文档" button
    /// writes the AI's updated full text back through `onSave`. Used by the goal
    /// panel — chat is the action, the document is the outcome.
    func startDocumentChat(title: String, markdown: String, onSave: @escaping (String) -> Void) {
        documentBinding = ChatDocumentBinding(title: title, markdown: markdown, onSave: onSave)
        chatStore.newConversation()
        oneShotTurns.removeAll()
        topAnchorMessageID = nil
        panel = .chat
        NotificationCenter.default.post(name: .houmaoEnterChatWindow, object: nil)
    }

    /// Extract the latest assistant reply's fenced document block and write it
    /// back to the bound source. No-op (with a hint) when there is no reply or
    /// the reply has no fenced block.
    func saveDocumentFromChat() {
        guard var binding = documentBinding else { return }
        guard let reply = chatStore.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text else {
            showError("还没有可保存的修改结果，先让 AI 给出修改。")
            return
        }
        guard let doc = Self.extractFencedBlock(reply) else {
            showError("AI 回复里没有找到文档代码块。请让它把完整全文放进 ```markdown 代码块。")
            return
        }
        binding.markdown = doc
        documentBinding = binding
        binding.onSave(doc)
    }

    /// The content of the first fenced code block (variable-length fence aware),
    /// used to pull the updated document out of the AI's reply.
    private static func extractFencedBlock(_ text: String) -> String? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            let ticks = t.prefix(while: { $0 == "`" }).count
            if ticks >= 3 {
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let c = lines[i].trimmingCharacters(in: .whitespaces)
                    if !c.isEmpty, c.allSatisfy({ $0 == "`" }), c.count >= ticks { break }
                    code.append(lines[i]); i += 1
                }
                let joined = code.joined(separator: "\n")
                return joined.isEmpty ? nil : joined
            }
            i += 1
        }
        return nil
    }

    /// The per-first-turn prompt for the document-bound chat: gives the AI the
    /// current document and asks it to apply the user's request and return the
    /// full updated document in a fenced block (so it can be saved back).
    private static func documentEditPrompt(doc: String, request: String) -> String {
        """
        你正在协助修改一份 Markdown 文档（目标文档：正文 + 结尾一段 ```mermaid 流程图）。请根据用户要求修改它，**保持未提及的内容不变**；需要时更新 mermaid 图（例如把已完成的步骤节点标记为完成、补充拆解步骤）。

        把修改后的**完整文档全文**包在一个代码块里输出，方便一键保存：外层用四个反引号 ````markdown 起、四个反引号结束；若文档内部本身有连续四个及以上反引号，就把外层围栏再加长一个。代码块之外可用一两句话说明改了什么。

        <当前文档>
        \(doc)
        </当前文档>

        用户要求：\(request)
        """
    }

    /// The fixed prompt for the editor's AI "repair Markdown format" button. The
    /// result is wrapped in a fenced code block so the chat renders it with a
    /// one-click Copy button that yields the raw fixed source (the outer fence is
    /// longer than any inner ``` so embedded code blocks stay intact).
    private static func markdownFixPrompt(_ markdown: String) -> String {
        """
        你是 Markdown 格式修复助手。请修复下面文档的 Markdown 格式问题（如标题 # 后缺空格、列表符号后缺空格、代码围栏未闭合、空链接、行尾多余空格、硬 Tab、表格对齐等），**保持原有文字内容与语义完全不变**，只调整格式。

        把修复后的**完整 Markdown 全文**包在一个代码块里输出，方便一键复制：外层用四个反引号 ````markdown 起、四个反引号结束；若文档内部本身出现连续四个及以上反引号，就把外层围栏再加长到比它多一个。代码块前后不要任何解释文字。

        <文档>
        \(markdown)
        </文档>
        """
    }

    /// The last http(s) link in the mail bodies (oldest→newest) — the bubble's
    /// clickable "关键链接". Format-matched, no LLM; trailing punctuation trimmed.
    static func lastMailLink(in mails: [MailMessageDetail]) -> URL? {
        let text = mails.map(\.body).joined(separator: "\n")
        let pattern = #"https?://[^\s<>"')\]]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.matches(in: text, range: range).last,
              let r = Range(match.range, in: text) else { return nil }
        var s = String(text[r])
        while let ch = s.last, ".,;:!?、，。".contains(ch) { s.removeLast() }
        return URL(string: s)
    }

    /// Distinct message subjects with common reply/forward prefixes stripped, in
    /// first-seen order — so a thread (cluster) collapses to its one title.
    private static func uniqueCleanSubjects(_ mails: [MailMessageDetail]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for mail in mails {
            let title = cleanSubject(mail.subject)
            if seen.insert(title).inserted { out.append(title) }
        }
        return out
    }

    /// Strip leading reply/forward prefixes (`Re:`, `Fwd:`, `回复：`…, repeated)
    /// so `Re: X` and `X` are treated as the same topic.
    private static func cleanSubject(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        let prefixes = ["re:", "re：", "fwd:", "fw:", "回复:", "回复：", "转发:", "转发："]
        while let p = prefixes.first(where: { s.lowercased().hasPrefix($0) }) {
            s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? "(无主题)" : s
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
        documentBinding = nil
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
        if documentBinding != nil, chatStore.historyMessages.isEmpty {
            // First turn of a document-bound chat: prime the LLM with the source
            // document so it can return an updated full version to save back.
            sentQuestion = Self.documentEditPrompt(doc: documentBinding!.markdown, request: question)
        } else if let context {
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
