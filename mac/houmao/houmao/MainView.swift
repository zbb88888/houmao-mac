import SwiftUI

struct MainView: View {
    @EnvironmentObject var viewModel: MainViewModel
    @EnvironmentObject var historyViewModel: HistoryViewModel
    @FocusState private var isInputFocused: Bool

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $viewModel.inputText, onCommit: {
                viewModel.submit(historyHandler: {
                    historyViewModel.load()
                    viewModel.toggleHistoryView()
                })
            })
            .textFieldStyle(.roundedBorder)
            .focused($isInputFocused)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if viewModel.isShowingHistory {
                            historyContent
                        } else {
                            chatContent
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
            }
        }
        .padding()
        .onExitCommand {
            // ESC 键隐藏窗口（不是关闭）
            NSApplication.shared.keyWindow?.orderOut(nil)
        }
        .onAppear {
            // 窗口出现时自动聚焦输入框
            isInputFocused = true

            // 监听窗口显示事件
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { _ in
                // 窗口变为 key window 时，聚焦输入框
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isInputFocused = true
                }
            }
        }
        .onChange(of: viewModel.isShowingHistory) {
            // 从 history 返回聊天时，自动聚焦输入框
            if !viewModel.isShowingHistory {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
    }

    @ViewBuilder
    private var historyContent: some View {
        Text("Usage History")
            .font(.title2)
            .bold()

        Text("以下为本机采集的使用情况记录，仅保存在本地。")
            .font(.footnote)
            .foregroundColor(.secondary)

        Divider()

        if historyViewModel.records.isEmpty {
            Text("暂无历史记录。")
                .foregroundColor(.secondary)
                .padding(.top, 8)
        } else {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(historyViewModel.records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dateFormatter.string(from: record.timestamp))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(record.text)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.gray.opacity(0.08))
                    .cornerRadius(6)
                }
            }
            .padding(.vertical, 4)
        }

        HStack {
            Button("返回对话") {
                viewModel.toggleHistoryView()
            }
            Spacer()
            Button("Clear All History") {
                historyViewModel.clearAll()
            }
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var chatContent: some View {
        if let user = viewModel.lastUserText, !user.isEmpty {
            Text("You:")
                .font(.headline)
            Text(user)
                .font(.system(size: 13, design: .monospaced))
        }

        if viewModel.isLoading {
            Text("LLM: Thinking...")
                .italic()
                .foregroundColor(.secondary)
        } else if let reply = viewModel.lastLLMReply, !reply.isEmpty {
            Text("LLM:")
                .font(.headline)
                .padding(.top, 8)
            Text(reply)
                .font(.system(size: 13, design: .monospaced))
        }
    }
}

