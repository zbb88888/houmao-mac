import Foundation

/// OpenAI-compatible LLM client with a configurable base URL.
nonisolated struct WorkerClient: LLMClient {
    let baseURL: String

    func ask(question: String, attachments: [Attachment]) async throws -> String {
        let endpoint = baseURL.hasSuffix("/")
            ? "\(baseURL)v1/chat/completions"
            : "\(baseURL)/v1/chat/completions"

        guard let url = URL(string: endpoint) else {
            throw error("Invalid worker URL: \(endpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = attachments.isEmpty ? 60 : 120

        // Build the user message content
        let content: Any
        if attachments.isEmpty {
            content = question
        } else {
            var parts: [[String: Any]] = []
            for att in attachments {
                switch att.content {
                case .image(_, let base64):
                    parts.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(base64)"]])
                case .audio(_, let base64, let format):
                    parts.append(["type": "input_audio", "input_audio": ["data": base64, "format": format]])
                }
            }
            parts.append(["type": "text", "text": question])
            content = parts
        }

        let body: [String: Any] = [
            "model": "default",
            "messages": [["role": "user", "content": content]],
            "stream": false
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Request failed"
            throw error(msg)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let responseContent = message["content"] as? String,
              !responseContent.isEmpty else {
            let debugInfo = String(data: data, encoding: .utf8) ?? "Unable to parse response"
            throw error("Invalid response: \(debugInfo)")
        }

        // Strip thinking process wrapped in <think>…</think> tags, keep only the final answer.
        let stripped = responseContent.replacingOccurrences(
            of: "<think>[\\s\\S]*?</think>",
            with: "",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        return stripped.isEmpty ? responseContent : stripped
    }

    private func error(_ message: String) -> Error {
        NSError(domain: "WorkerClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
