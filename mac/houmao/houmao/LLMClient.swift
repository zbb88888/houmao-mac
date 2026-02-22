import Foundation

nonisolated protocol LLMClient: Sendable {
    func ask(question: String) async throws -> String
}

nonisolated struct MockLLMClient: LLMClient {
    init() {}

    func ask(question: String) async throws -> String {
        try await Task.sleep(for: .milliseconds(600))
        return "Mock LLM 回复：你刚才问的是「\(question)」。未来这里会接入 MiniCPM-V。"
    }
}
