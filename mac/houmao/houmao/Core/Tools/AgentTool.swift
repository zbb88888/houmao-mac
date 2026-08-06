import Foundation

/// A capability the agent can invoke. Each tool wraps an existing deterministic
/// houmao capability (fetching mail, listing PRs, analyzing a diff …) — the same
/// info flow a user triggers manually from a panel, minus the clicking.
protocol AgentTool: Sendable {
    /// Function name exposed to the model (snake_case, stable).
    var name: String { get }
    /// One-line description the model uses to decide when to call this tool.
    var description: String { get }
    /// JSON Schema object describing the arguments (`.object([...])`).
    var parametersSchema: JSONValue { get }
    /// Whether invoking this tool changes user data (delete mail, write file …).
    /// Mutating tools are never auto-executed; `AgentLoop` pauses for human
    /// confirmation before running them (ADR-8: no autonomous writes).
    var isMutating: Bool { get }
    /// Execute with the decoded arguments; return a text result fed back to the
    /// model as the tool's output.
    func invoke(arguments: JSONValue) async throws -> String
}

extension AgentTool {
    var isMutating: Bool { false }
}

/// A tool call the model requested in an assistant turn.
struct ToolCall: Sendable, Equatable {
    let id: String
    let name: String
    let arguments: JSONValue
}

/// One assistant turn from the model: optional text plus any tool calls. When
/// `toolCalls` is empty the `content` is the final answer.
struct AssistantTurn: Sendable, Equatable {
    let content: String?
    let toolCalls: [ToolCall]

    init(content: String? = nil, toolCalls: [ToolCall] = []) {
        self.content = content
        self.toolCalls = toolCalls
    }
}
