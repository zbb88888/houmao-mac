import Foundation

/// Speaks the OpenAI tool-calling wire format for `AgentLoop`. Kept separate
/// from `AiTxtClient` so the existing chat/mail/pipeline paths are untouched:
/// all `tools` / `tool_calls` encoding and parsing lives here.
struct AgentModelClient: Sendable {
    let baseURL: String
    let model: String
    let apiKey: String
    /// Optional agent instructions prepended as the first `system` message.
    var systemPrompt: String = ""
    var timeout: TimeInterval = 180

    /// Adapter for `AgentLoop.ModelCall`.
    var modelCall: AgentLoop.ModelCall {
        { messages, tools in try await complete(messages, tools: tools) }
    }

    /// Send the transcript + tool specs (non-streaming) and parse the assistant
    /// turn (final text and/or tool calls).
    func complete(_ messages: [AgentMessage], tools: [JSONValue]) async throws -> AssistantTurn {
        let endpoint = baseURL.hasSuffix("/")
            ? "\(baseURL)v1/chat/completions"
            : "\(baseURL)/v1/chat/completions"
        guard let url = URL(string: endpoint) else { throw ClientError.invalidURL(endpoint) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = timeout
        let body = Self.requestBody(model: model, systemPrompt: systemPrompt, messages: messages, tools: tools)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.requestFailed("No HTTP response received")
        }
        guard (200...299).contains(http.statusCode) else {
            let b = String(data: data, encoding: .utf8) ?? ""
            let truncated = b.count > 500 ? String(b.prefix(500)) + "..." : b
            throw ClientError.requestFailed("HTTP \(http.statusCode): \(truncated)")
        }
        return try Self.parseTurn(data)
    }

    // MARK: - Wire encoding (pure, testable)

    /// Build the `/v1/chat/completions` request body. `tools` is omitted when empty.
    static func requestBody(model: String, systemPrompt: String, messages: [AgentMessage], tools: [JSONValue]) -> JSONValue {
        var wire: [JSONValue] = []
        if !systemPrompt.isEmpty {
            wire.append(.object(["role": .string("system"), "content": .string(systemPrompt)]))
        }
        wire.append(contentsOf: messages.map(messageJSON))

        var obj: [String: JSONValue] = [
            "model": .string(model),
            "messages": .array(wire),
            "stream": .bool(false),
        ]
        if !tools.isEmpty { obj["tools"] = .array(tools) }
        return .object(obj)
    }

    private static func messageJSON(_ m: AgentMessage) -> JSONValue {
        switch m.role {
        case .user:
            return .object(["role": .string("user"), "content": .string(m.content)])
        case .assistant:
            var obj: [String: JSONValue] = ["role": .string("assistant")]
            obj["content"] = m.content.isEmpty ? .null : .string(m.content)
            if !m.toolCalls.isEmpty {
                obj["tool_calls"] = .array(m.toolCalls.map { tc in
                    .object([
                        "id": .string(tc.id),
                        "type": .string("function"),
                        "function": .object([
                            "name": .string(tc.name),
                            // OpenAI requires arguments as a JSON-encoded string.
                            "arguments": .string(encodeArguments(tc.arguments)),
                        ]),
                    ])
                })
            }
            return .object(obj)
        case .tool:
            return .object([
                "role": .string("tool"),
                "tool_call_id": .string(m.toolCallID ?? ""),
                "content": .string(m.content),
            ])
        }
    }

    private static func encodeArguments(_ v: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(v), let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - Response parsing (pure, testable)

    /// Extract the assistant turn from a completion response.
    static func parseTurn(_ data: Data) throws -> AssistantTurn {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let message = root["choices"]?.arrayValue?.first?["message"] else {
            throw ClientError.invalidResponse(String(data: data, encoding: .utf8) ?? "no message in response")
        }

        // Fall back to `reasoning_content` for reasoning models that leave
        // `content` empty (parity with AiTxtClient).
        let raw = message["content"]?.stringValue ?? message["reasoning_content"]?.stringValue
        let content = raw.map(stripThink)

        var calls: [ToolCall] = []
        if let arr = message["tool_calls"]?.arrayValue {
            for tc in arr {
                guard let fn = tc["function"], let fnName = fn["name"]?.stringValue else { continue }
                let id = tc["id"]?.stringValue ?? UUID().uuidString
                let argsStr = fn["arguments"]?.stringValue ?? "{}"
                let args = (try? JSONDecoder().decode(JSONValue.self, from: Data(argsStr.utf8))) ?? .object([:])
                calls.append(ToolCall(id: id, name: fnName, arguments: args))
            }
        }

        let finalContent = (content?.isEmpty == true) ? nil : content
        return AssistantTurn(content: finalContent, toolCalls: calls)
    }

    /// Drop reasoning traces: everything up to and including the last `</think>`.
    private static func stripThink(_ s: String) -> String {
        let stripped = s
            .replacingOccurrences(of: "^[\\s\\S]*</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? s : stripped
    }
}
