import Foundation

/// AI text client for local LLM.
nonisolated struct AiTxtClient: LLMClient {
    func ask(question: String) async throws -> String {
        guard let url = URL(string: "http://localhost:8080/v1/chat/completions") else {
            throw NSError(domain: "AiTxtClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"])
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 300

        let body: [String: Any] = [
            "model": "minicpm-o-4.5",
            "messages": [["role": "user", "content": question]],
            "stream": false
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let msg = String(data: data, encoding: .utf8) ?? "Request failed"
            throw NSError(domain: "AiTxtClient", code: -2, userInfo: [NSLocalizedDescriptionKey: msg])
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            let debugInfo = String(data: data, encoding: .utf8) ?? "Unable to parse response"
            throw NSError(domain: "AiTxtClient", code: -3, userInfo: [NSLocalizedDescriptionKey: "Invalid response: \(debugInfo)"])
        }

        return content
    }
}
