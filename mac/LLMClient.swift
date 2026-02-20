import Foundation

protocol LLMClient {
    func ask(question: String, completion: @escaping (Result<String, Error>) -> Void)
}

struct MockLLMClient: LLMClient {
    enum MockError: Error {
        case failed
    }

    func ask(question: String, completion: @escaping (Result<String, Error>) -> Void) {
        // 简单的 mock：延迟一小段时间后返回固定回复
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
            let reply = "Mock LLM 回复：你刚才问的是「\(question)」。未来这里会接入 MiniCPM-V。"
            completion(.success(reply))
        }
    }
}

