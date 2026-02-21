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
        VStack(alignment: .leading, spacing: 0) {
            // 输入框 - 永远显示
            TextField("Type something...", text: $viewModel.inputText, onCommit: {
                viewModel.submit(historyHandler: {
                    historyViewModel.load()
                    viewModel.toggleHistoryView()
                })
            })
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .focused($isInputFocused)
            .padding(16)

            // 结果显示框 - 只在有内容时显示
            if shouldShowResults {
                Divider()
                    .padding(.horizontal, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if viewModel.isShowingHistory {
                            historyContent
                        } else {
                            chatContent
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                }
                .frame(height: 300)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 600)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.windowBackgroundColor))
                .shadow(color: Color.black.opacity(0.2), radius: 20, x: 0, y: 10)
        )
        .onExitCommand {
            // ESC 键隐藏窗口（不是关闭）
            NSApplication.shared.keyWindow?.orderOut(nil)
        }
        .onAppear {
            // 设置窗口为无边框、透明背景
            if let window = NSApplication.shared.keyWindow {
                window.isOpaque = false
                window.backgroundColor = .clear
                window.hasShadow = false  // 我们使用 SwiftUI 的阴影
                window.styleMask.remove([.closable, .miniaturizable, .resizable])
            }

            // 窗口出现时自动聚焦输入框
            isInputFocused = true

            // 监听窗口显示事件
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { _ in
                // 窗口变为 key window 时，聚焦输入框并设置窗口样式
                if let window = NSApplication.shared.keyWindow {
                    window.isOpaque = false
                    window.backgroundColor = .clear
                    window.hasShadow = false
                    window.styleMask.remove([.closable, .miniaturizable, .resizable])
                }

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

    // 判断是否应该显示结果区域
    private var shouldShowResults: Bool {
        viewModel.isShowingHistory ||
        viewModel.isLoading ||
        (viewModel.lastUserText != nil && !viewModel.lastUserText!.isEmpty) ||
        (viewModel.lastLLMReply != nil && !viewModel.lastLLMReply!.isEmpty)
    }

    @ViewBuilder
    private var historyContent: some View {
        HStack {
            Text("Usage History")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(action: {
                viewModel.toggleHistoryView()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }

        if historyViewModel.records.isEmpty {
            Text("No history yet")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(historyViewModel.records) { record in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(dateFormatter.string(from: record.timestamp))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(record.text)
                            .font(.system(size: 12))
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.gray.opacity(0.05))
                    .cornerRadius(6)
                }
            }
            .padding(.vertical, 8)

            Button("Clear All") {
                historyViewModel.clearAll()
            }
            .font(.system(size: 12))
            .foregroundColor(.red)
            .padding(.top, 4)
        }
    }

    @ViewBuilder
    private var chatContent: some View {
        if let user = viewModel.lastUserText, !user.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text("Q:")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(user)
                    .font(.system(size: 13))
            }
        }

        if viewModel.isLoading {
            HStack(alignment: .top, spacing: 8) {
                Text("A:")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                ProgressView()
                    .scaleEffect(0.6)
                    .frame(width: 16, height: 16)
                Text("Thinking...")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            .padding(.top, 8)
        } else if let reply = viewModel.lastLLMReply, !reply.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Text("A:")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
                Text(reply)
                    .font(.system(size: 13))
            }
            .padding(.top, 8)
        }
    }
}

