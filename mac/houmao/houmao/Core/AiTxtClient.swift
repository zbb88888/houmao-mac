import Foundation

enum ClientError: LocalizedError {
    case invalidURL(String)
    case requestFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .requestFailed(let msg): return msg
        case .invalidResponse(let debug): return "Invalid response: \(debug)"
        }
    }
}

// MARK: - OpenAI Models

struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let stream: Bool
}

struct ChatMessage: Encodable {
    let role: String
    let content: ChatMessageContent
}

enum ChatMessageContent: Encodable {
    case text(String)
    case parts([ContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let str):
            try container.encode(str)
        case .parts(let parts):
            try container.encode(parts)
        }
    }
}

enum ContentPart: Encodable {
    case text(String)
    case image(url: String)
    case audio(data: String, format: String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let url):
            try container.encode("image_url", forKey: .type)
            try container.encode(["url": url], forKey: .imageUrl)
        case .audio(let data, let format):
            try container.encode("input_audio", forKey: .type)
            try container.encode(["data": data, "format": format], forKey: .inputAudio)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageUrl = "image_url"
        case inputAudio = "input_audio"
    }
}

struct ChatResponse: Decodable {
    let choices: [ChatChoice]
}

struct ChatChoice: Decodable {
    let message: ChatResponseMessage?
    let delta: ChatResponseMessage?
}

struct ChatResponseMessage: Decodable {
    let content: String?
    let reasoningContent: String?

    enum CodingKeys: String, CodingKey {
        case content
        case reasoningContent = "reasoning_content"
    }
}

// MARK: - Client

/// OpenAI-compatible LLM client with configurable base URL.
struct AiTxtClient: Sendable {
    let baseURL: String
    let model: String
    let apiKey: String

    init(baseURL: String, model: String, apiKey: String = "") {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
    }

    // MARK: - Shared helpers

    private func buildRequest(stream: Bool, question: String, attachments: [Attachment], history: [ChatMessage]) throws -> URLRequest {
        let endpoint = baseURL.hasSuffix("/")
            ? "\(baseURL)v1/chat/completions"
            : "\(baseURL)/v1/chat/completions"

        guard let url = URL(string: endpoint) else {
            throw ClientError.invalidURL(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120

        let content: ChatMessageContent
        if attachments.isEmpty {
            content = .text(question)
        } else {
            var parts: [ContentPart] = []
            for att in attachments {
                switch att.content {
                case .image:
                    parts.append(.image(url: "data:image/jpeg;base64,\(att.base64)"))
                case .audio(_, _, let format):
                    parts.append(.audio(data: att.base64, format: format))
                }
            }
            parts.append(.text(question))
            content = .parts(parts)
        }

        let body = ChatRequest(
            model: model,
            messages: history + [ChatMessage(role: "user", content: content)],
            stream: stream
        )
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    // MARK: - Non-streaming

    func ask(question: String, attachments: [Attachment], history: [ChatMessage] = []) async throws -> String {
        let request = try buildRequest(stream: false, question: question, attachments: attachments, history: history)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.requestFailed("No HTTP response received")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let truncated = body.count > 500 ? String(body.prefix(500)) + "..." : body
            throw ClientError.requestFailed("HTTP \(httpResponse.statusCode): \(truncated)")
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        let msg = chatResponse.choices.first?.message ?? chatResponse.choices.first?.delta
        let responseContent = msg?.content?.isEmpty == false ? msg?.content
            : msg?.reasoningContent
        guard let responseContent, !responseContent.isEmpty else {
            let debugInfo = String(data: data, encoding: .utf8) ?? "Unable to parse response"
            throw ClientError.invalidResponse(debugInfo)
        }

        // Strip thinking process: drop everything up to and including the last </think>.
        let stripped = responseContent
            .replacingOccurrences(of: "^[\\s\\S]*</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return stripped.isEmpty ? responseContent : stripped
    }

    // MARK: - Streaming

    /// Stream chat completions via SSE. Calls `onToken` on each delta content chunk.
    /// Returns the full assembled response after the stream completes.
    func askStream(
        question: String,
        attachments: [Attachment],
        history: [ChatMessage] = [],
        onToken: @Sendable @escaping (String) -> Void
    ) async throws -> String {
        let request = try buildRequest(stream: true, question: question, attachments: attachments, history: history)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ClientError.requestFailed("No HTTP response received")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
                if errorBody.count > 500 { break }
            }
            let truncated = errorBody.count > 500 ? errorBody.prefix(500) + "..." : errorBody[...]
            throw ClientError.requestFailed("HTTP \(httpResponse.statusCode): \(truncated)")
        }

        var fullResponse = ""
        var insideThink = false

        for try await line in bytes.lines {
            guard !Task.isCancelled else { break }

            guard line.hasPrefix("data:") else { continue }
            // Some providers emit "data:{...}" without a space after the colon
            // (e.g. Youdao llmgateway), so strip the prefix then trim whitespace.
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }

            guard let chunkData = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(ChatResponse.self, from: chunkData),
                  let delta = chunk.choices.first?.delta,
                  let token = delta.content, !token.isEmpty
            else { continue }

            // Filter out <think>...</think> content in streaming
            var remaining = token
            while !remaining.isEmpty {
                if insideThink {
                    if let endRange = remaining.range(of: "</think>") {
                        insideThink = false
                        remaining = String(remaining[endRange.upperBound...])
                    } else {
                        break // Still inside think block, discard
                    }
                } else {
                    if let startRange = remaining.range(of: "<think>") {
                        let before = String(remaining[remaining.startIndex..<startRange.lowerBound])
                        if !before.isEmpty {
                            fullResponse += before
                            onToken(before)
                        }
                        insideThink = true
                        remaining = String(remaining[startRange.upperBound...])
                    } else {
                        fullResponse += remaining
                        onToken(remaining)
                        break
                    }
                }
            }
        }

        let trimmed = fullResponse.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fullResponse : trimmed
    }
}
