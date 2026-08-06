import Foundation

/// One message in the agent's transcript. Decoupled from `AiTxtClient`'s wire
/// types so the loop stays pure and testable; the injected model call maps these
/// onto the transport when the real client is wired in.
struct AgentMessage: Sendable, Equatable {
    enum Role: String, Sendable, Equatable { case user, assistant, tool }

    var role: Role
    var content: String
    /// Tool calls requested by an assistant turn.
    var toolCalls: [ToolCall]
    /// For a `tool` message: the id of the call this result answers.
    var toolCallID: String?

    init(role: Role, content: String, toolCalls: [ToolCall] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }

    static func user(_ text: String) -> AgentMessage { .init(role: .user, content: text) }
    static func assistant(_ turn: AssistantTurn) -> AgentMessage {
        .init(role: .assistant, content: turn.content ?? "", toolCalls: turn.toolCalls)
    }
    static func toolResult(id: String, _ text: String) -> AgentMessage {
        .init(role: .tool, content: text, toolCallID: id)
    }
}

/// Progress reported by the loop for the UI. Named to avoid colliding with the
/// proactive-agency `AgentEvent` (that subsystem is about passive watching, this
/// is about tool use).
enum AgentActivity: Sendable {
    case willCall(ToolCall)
    case didCall(ToolCall, result: String)
}

/// How a loop run ended.
enum AgentOutcome: Sendable, Equatable {
    /// The model produced a final answer (no more tool calls).
    case finished(String)
    /// A mutating tool needs user confirmation before it runs. The transcript is
    /// returned so the caller can `resume` after the user approves.
    case awaitingConfirmation(call: ToolCall, transcript: [AgentMessage])
    /// The step budget ran out before a final answer.
    case maxStepsReached
}

/// The tool-use loop: request → tool calls → execute → feed results back →
/// re-ask → until a final answer. Single-tool use is just the loop running one
/// iteration; multi-step chaining falls out of the same loop. Mutating tools are
/// never auto-executed (ADR-8) — the loop pauses and returns
/// `.awaitingConfirmation`.
struct AgentLoop: Sendable {
    /// Injected model call: given the transcript and tool specs, return the next
    /// assistant turn. The real impl wraps `AiTxtClient`; tests inject a script.
    typealias ModelCall = @Sendable ([AgentMessage], [JSONValue]) async throws -> AssistantTurn

    let registry: ToolRegistry
    let model: ModelCall
    /// Safety cap on iterations so a looping model can't run forever.
    var maxSteps: Int = 8

    /// Run until the model returns a final answer, a mutating tool needs
    /// confirmation, or the step budget is exhausted. `onEvent` reports progress
    /// for the UI and never blocks the loop.
    func run(
        transcript initial: [AgentMessage],
        onEvent: (@Sendable (AgentActivity) -> Void)? = nil
    ) async throws -> AgentOutcome {
        var transcript = initial
        for _ in 0..<maxSteps {
            let turn = try await model(transcript, registry.specs())
            transcript.append(.assistant(turn))

            if turn.toolCalls.isEmpty {
                return .finished(turn.content ?? "")
            }

            for call in turn.toolCalls {
                onEvent?(.willCall(call))

                guard let tool = registry.tool(named: call.name) else {
                    transcript.append(.toolResult(id: call.id, "error: unknown tool \"\(call.name)\""))
                    continue
                }

                if tool.isMutating {
                    // Pause before any write (ADR-8). Assumes the model emits a
                    // mutating call on its own turn; a turn mixing it with other
                    // calls would leave those unanswered on resume.
                    return .awaitingConfirmation(call: call, transcript: transcript)
                }

                let result: String
                do {
                    result = try await tool.invoke(arguments: call.arguments)
                } catch {
                    result = "error: \(error.localizedDescription)"
                }
                onEvent?(.didCall(call, result: result))
                transcript.append(.toolResult(id: call.id, result))
            }
        }
        return .maxStepsReached
    }

    /// Resume after the user approved a paused mutating tool: execute it, append
    /// its result, and continue the loop.
    func resume(
        afterApproving call: ToolCall,
        transcript: [AgentMessage],
        onEvent: (@Sendable (AgentActivity) -> Void)? = nil
    ) async throws -> AgentOutcome {
        guard let tool = registry.tool(named: call.name) else {
            var t = transcript
            t.append(.toolResult(id: call.id, "error: unknown tool \"\(call.name)\""))
            return try await run(transcript: t, onEvent: onEvent)
        }
        onEvent?(.willCall(call))
        let result: String
        do {
            result = try await tool.invoke(arguments: call.arguments)
        } catch {
            result = "error: \(error.localizedDescription)"
        }
        onEvent?(.didCall(call, result: result))
        var t = transcript
        t.append(.toolResult(id: call.id, result))
        return try await run(transcript: t, onEvent: onEvent)
    }
}
