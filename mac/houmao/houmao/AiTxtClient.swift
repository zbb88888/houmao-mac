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
    let message: ChatResponseMessage
}

struct ChatResponseMessage: Decodable {
    let content: String?
}

// MARK: - Client

/// OpenAI-compatible LLM client with configurable base URL.
struct AiTxtClient: Sendable {
    let baseURL: String
    let model: String

    init(baseURL: String, model: String = "minicpm-o-4.5") {
        self.baseURL = baseURL
        self.model = model
    }

    func ask(question: String, attachments: [Attachment]) async throws -> String {
        let endpoint = baseURL.hasSuffix("/")
            ? "\(baseURL)v1/chat/completions"
            : "\(baseURL)/v1/chat/completions"

        guard let url = URL(string: endpoint) else {
            throw ClientError.invalidURL(endpoint)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = attachments.isEmpty ? 60 : 120

        // Build the user message content
        let content: ChatMessageContent
        if attachments.isEmpty {
            content = .text(question)
        } else {
            var parts: [ContentPart] = []
            for att in attachments {
                switch att.content {
                case .image(_, let base64):
                    parts.append(.image(url: "data:image/jpeg;base64,\(base64)"))
                case .audio(_, let base64, let format):
                    parts.append(.audio(data: base64, format: format))
                }
            }
            parts.append(.text(question))
            content = .parts(parts)
        }

        let body = ChatRequest(
            model: model,
            messages: [ChatMessage(role: "user", content: content)],
            stream: false
        )

        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Request failed"
            throw ClientError.requestFailed(msg)
        }

        let chatResponse = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let responseContent = chatResponse.choices.first?.message.content,
              !responseContent.isEmpty else {
            let debugInfo = String(data: data, encoding: .utf8) ?? "Unable to parse response"
            throw ClientError.invalidResponse(debugInfo)
        }

        // Strip thinking process: drop everything up to and including the last </think>.
        let stripped = responseContent
            .replacingOccurrences(of: "^[\\s\\S]*</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return stripped.isEmpty ? responseContent : stripped
    }
}
