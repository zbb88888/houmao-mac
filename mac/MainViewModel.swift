import Foundation
import AppKit

final class MainViewModel: ObservableObject {
    @Published var inputText: String = ""
    @Published var lastUserText: String?
    @Published var lastLLMReply: String?
    @Published var isLoading: Bool = false
    @Published var isHistoryPresented: Bool = false

    private let llmClient: LLMClient

    init(llmClient: LLMClient) {
        self.llmClient = llmClient
    }

    /// 处理用户提交。historyHandler 在检测到 history 命令时被调用。
    func submit(historyHandler: () -> Void) {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // history 命令（忽略大小写）
        if trimmed.lowercased() == "history" {
            inputText = ""
            historyHandler()
            return
        }

        lastUserText = trimmed
        lastLLMReply = nil
        inputText = ""
        isLoading = true

        llmClient.ask(question: trimmed) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                switch result {
                case .success(let reply):
                    self.lastLLMReply = reply
                case .failure(let error):
                    self.lastLLMReply = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    func showHistoryWindow() {
        isHistoryPresented = true
    }
}

