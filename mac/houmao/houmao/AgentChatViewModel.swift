import Foundation
import Observation

/// Drives the standalone AI-agent window (`/ai`): a tool-using conversation.
/// The user states an intent, the model decides which tools to call, the loop
/// executes read-only tools automatically and pauses mutating ones for
/// confirmation (ADR-8). This is the first AI-native entry point; the existing
/// deterministic panels stay as-is (hybrid path).
@MainActor
@Observable
final class AgentChatViewModel {
    struct Item: Identifiable {
        enum Kind { case user, toolCall, toolResult, assistant, error }
        let id = UUID()
        let kind: Kind
        var text: String
    }

    private(set) var items: [Item] = []
    var input: String = ""
    private(set) var isRunning = false
    /// True when the last run ended in a failure the user can retry.
    private(set) var lastRunFailed = false
    /// Set when a mutating tool is paused awaiting the user's approval.
    private(set) var pendingConfirmation: (call: ToolCall, transcript: [AgentMessage])?
    /// Free-text filter set by the command palette (matches item text).
    var searchFilter: String = ""

    /// Tools the agent may call. Grows as capabilities are wrapped (hybrid path).
    private let registry: ToolRegistry
    private var task: Task<Void, Never>?
    /// The transcript of the last `run`, replayed by `retry()`.
    private var lastTranscript: [AgentMessage]?

    init() {
        // Mail tools reuse the shared Gmail provider (same read path as /mail).
        let mail = GmailProvider(accessTokenProvider: { try await GoogleAccount.accessToken() })
        registry = ToolRegistry([
            ListPullRequestsTool(),
            ListRecentMailTool(provider: mail),
            ReadMailTool(provider: mail),
            TriageInboxTool(provider: mail, customTags: AppSettings.shared.mailTags),
            TrashMailTool(provider: mail),
        ])
    }

    private static let systemPrompt = """
    你是猴毛（houmao）的智能助手。你可以调用工具来获取 GitHub PR、Gmail 邮件等数据后再回答。\
    想快速了解重要邮件用 triage_inbox；要看具体某封先 list_recent_mail 再 read_mail；\
    删邮件用 trash_mail（会先请用户确认）。\
    需要数据时调用相应工具，不要臆造；工具返回后基于结果作答。优先用简体中文回复。
    """

    var displayedItems: [Item] {
        let q = searchFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.text.lowercased().contains(q) }
    }

    // MARK: - User actions

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isRunning else { return }
        input = ""
        items.append(Item(kind: .user, text: text))
        run(transcript: [.user(text)])
    }

    func clear() {
        task?.cancel()
        items.removeAll()
        pendingConfirmation = nil
        isRunning = false
        lastRunFailed = false
        lastTranscript = nil
    }

    /// Whether the last run failed and can be replayed.
    var canRetry: Bool { !isRunning && lastRunFailed && lastTranscript != nil }

    /// Replay the last request (after a failure) without retyping.
    func retry() {
        guard canRetry, let transcript = lastTranscript else { return }
        run(transcript: transcript)
    }

    func approvePending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        resume(call: pending.call, transcript: pending.transcript)
    }

    func rejectPending() {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        items.append(Item(kind: .toolResult, text: "已取消该操作。"))
        // Tell the model the tool was declined so it can wrap up without it.
        let transcript = pending.transcript + [.toolResult(id: pending.call.id, "user declined to run this tool")]
        run(transcript: transcript)
    }

    // MARK: - Loop plumbing

    private func makeLoop() -> AgentLoop? {
        guard let resolved = AppSettings.shared.resolveModel(named: nil) else {
            items.append(Item(kind: .error, text: "未配置模型。打开设置（⌘,）添加一个 provider。"))
            return nil
        }
        let client = AgentModelClient(
            baseURL: resolved.provider.apiHost,
            model: resolved.model,
            apiKey: resolved.provider.apiKey,
            systemPrompt: Self.systemPrompt
        )
        return AgentLoop(registry: registry, model: client.modelCall)
    }

    private func run(transcript: [AgentMessage]) {
        lastTranscript = transcript
        guard let loop = makeLoop() else {
            lastRunFailed = true
            return
        }
        startTask { onEvent in try await loop.run(transcript: transcript, onEvent: onEvent) }
    }

    private func resume(call: ToolCall, transcript: [AgentMessage]) {
        guard let loop = makeLoop() else { return }
        startTask { onEvent in try await loop.resume(afterApproving: call, transcript: transcript, onEvent: onEvent) }
    }

    private func startTask(
        _ body: @escaping @Sendable (@escaping @Sendable (AgentActivity) -> Void) async throws -> AgentOutcome
    ) {
        isRunning = true
        lastRunFailed = false
        task?.cancel()
        task = Task { [weak self] in
            let onEvent: @Sendable (AgentActivity) -> Void = { activity in
                Task { @MainActor [weak self] in self?.handle(activity) }
            }
            do {
                let outcome = try await body(onEvent)
                await MainActor.run { self?.finish(outcome: outcome) }
            } catch is CancellationError {
                await MainActor.run { self?.isRunning = false }
            } catch {
                await MainActor.run {
                    self?.items.append(Item(kind: .error, text: "出错：\(error.localizedDescription)"))
                    self?.lastRunFailed = true
                    self?.isRunning = false
                }
            }
        }
    }

    private func handle(_ activity: AgentActivity) {
        switch activity {
        case .willCall(let call):
            items.append(Item(kind: .toolCall, text: summary(call)))
        case .didCall(_, let result):
            items.append(Item(kind: .toolResult, text: result))
        }
    }

    private func finish(outcome: AgentOutcome) {
        switch outcome {
        case .finished(let answer):
            if answer.isEmpty {
                items.append(Item(kind: .error, text: "模型没有返回内容，可点「重试」。"))
                lastRunFailed = true
            } else {
                items.append(Item(kind: .assistant, text: answer))
                lastRunFailed = false
            }
        case .awaitingConfirmation(let call, let transcript):
            pendingConfirmation = (call, transcript)
            items.append(Item(kind: .toolCall, text: "⚠️ 需要确认后才会执行：\(summary(call))"))
            lastRunFailed = false
        case .maxStepsReached:
            items.append(Item(kind: .error, text: "达到最大步数仍未得到最终回答。"))
            lastRunFailed = true
        }
        isRunning = false
    }

    private func summary(_ call: ToolCall) -> String {
        if let data = try? JSONEncoder().encode(call.arguments),
           let s = String(data: data, encoding: .utf8), s != "{}" {
            return "调用工具 \(call.name) \(s)"
        }
        return "调用工具 \(call.name)"
    }
}
