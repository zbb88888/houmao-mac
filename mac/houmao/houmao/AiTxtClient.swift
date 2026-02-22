import Foundation

/// AI text client for local LLM.
nonisolated struct AiTxtClient: LLMClient {
    private let baseURL: String
    private let apiKey: String
    private let model: String

    init(
        baseURL: String = "http://localhost:8080/v1",
        apiKey: String = "not-needed",
        model: String = "minicpm-o-4.5"
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    func ask(question: String) async throws -> String {
        // Build request
        guard let url = URL(string: "\(baseURL)/chat/completions") else {
            throw AiTxtError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300

        // Build request body using JSONSerialization
        let requestBody: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": question]
            ],
            "stream": false
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        // Perform request
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AiTxtError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let errorMsg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw AiTxtError.httpError(statusCode: httpResponse.statusCode, message: errorMsg)
        }

        // Parse response
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw AiTxtError.emptyResponse
        }

        return content
    }
}

// MARK: - Errors

enum AiTxtError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, message: String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let statusCode, let message):
            return "HTTP error \(statusCode): \(message)"
        case .emptyResponse:
            return "Empty response from LLM"
        }
    }
}
