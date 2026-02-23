import Foundation

/// AI text client for local LLM.
nonisolated struct AiTxtClient: LLMClient {
    func ask(question: String, imageBase64s: [String], audioBase64s: [(data: String, format: String)]) async throws -> String {
        let url = URL(string: "http://localhost:8080/v1/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let hasMedia = !imageBase64s.isEmpty || !audioBase64s.isEmpty
        request.timeoutInterval = hasMedia ? 120 : 60

        // Build the user message content
        let content: Any
        if !hasMedia {
            content = question
        } else {
            var parts: [[String: Any]] = imageBase64s.map { base64 in
                [
                    "type": "image_url",
                    "image_url": ["url": "data:image/jpeg;base64,\(base64)"]
                ]
            }
            parts += audioBase64s.map { audio in
                [
                    "type": "input_audio",
                    "input_audio": ["data": audio.data, "format": audio.format]
                ]
            }
            parts.append(["type": "text", "text": question])
            content = parts
        }

        let body: [String: Any] = [
            "model": "minicpm-o-4.5",
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
        NSError(domain: "AiTxtClient", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
