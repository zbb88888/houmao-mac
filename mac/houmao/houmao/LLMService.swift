import Foundation
import OpenAI

/// Service to interact with OpenAI-compatible LLMs natively.
struct LLMService {
    private let client: OpenAI

    /// Initialize with optional API key and base URL.
    /// If not provided, it reads from environment variables OPENAI_API_KEY and BASE_URL.
    init(apiKey: String? = nil, baseURL: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        let token = apiKey ?? env["OPENAI_API_KEY"] ?? "no-key-needed"
        let urlString = baseURL ?? env["BASE_URL"] ?? "http://localhost:19060"

        // Extract host and scheme from URL
        let url = URL(string: urlString)
        let host = url?.host ?? "localhost"
        let scheme = url?.scheme ?? "http"
        let port = url?.port ?? (scheme == "https" ? 443 : 80)

        let configuration = OpenAI.Configuration(
            token: token,
            host: host,
            port: port,
            scheme: scheme
        )
        self.client = OpenAI(configuration: configuration)
    }

    /// Stream AI response for a given question and attachments.
    func stream(question: String, model: String, attachments: [Attachment]) -> AsyncThrowingStream<String, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    // Build messages
                    let messages: [ChatQuery.ChatCompletionMessageParam]
                    if attachments.isEmpty {
                        guard let msg = ChatQuery.ChatCompletionMessageParam(role: .user, content: .string(question)) else {
                            continuation.finish(throwing: NSError(domain: "LLMService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create message"]))
                            return
                        }
                        messages = [msg]
                    } else {
                        var visionContent: [ChatQuery.ChatCompletionMessageParam.Content.VisionContent] = []
                        for att in attachments {
                            switch att.content {
                            case .image(_, let base64):
                                visionContent.append(.init(type: .imageUrl, imageUrl: .init(url: "data:image/jpeg;base64,\(base64)", detail: .auto)))
                            case .audio:
                                // Audio support in ChatQuery depends on library version.
                                // Skipping for now to ensure compatibility with basic vision/text.
                                break
                            }
                        }
                        visionContent.append(.init(type: .text, text: question))
                        guard let msg = ChatQuery.ChatCompletionMessageParam(role: .user, content: .vision(visionContent)) else {
                            continuation.finish(throwing: NSError(domain: "LLMService", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create vision message"]))
                            return
                        }
                        messages = [msg]
                    }

                    let query = ChatQuery(model: model, messages: messages, stream: true)

                    for try await result in client.chatsStream(query: query) {
                        if let delta = result.choices.first?.delta.content {
                            continuation.yield(delta)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
