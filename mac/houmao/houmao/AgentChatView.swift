import SwiftUI

/// The standalone AI-agent conversation (`/ai`). Shows the user's messages, the
/// tools the agent chose to call and their results, and the final answer.
/// Mutating tools surface a confirm bar before they run (ADR-8).
struct AgentChatView: View {
    @Environment(AgentChatViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    var body: some View {
        @Bindable var vm = viewModel
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            if let pending = viewModel.pendingConfirmation {
                confirmationBar(pending.call)
                Divider()
            }
            inputBar(input: $vm.input)
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button { viewModel.clear() } label: { Image(systemName: "square.and.pencil") }
                .help("新对话")
            Spacer()
            if viewModel.canRetry {
                Button { viewModel.retry() } label: {
                    Label("重试", systemImage: "arrow.clockwise")
                }
                .help("重试上一次请求")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if viewModel.items.isEmpty { emptyState }
                    ForEach(viewModel.displayedItems) { row($0) }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: viewModel.items.count) {
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("智能助手")
                .font(.system(size: 15, weight: .semibold))
            Text("用自然语言描述你的意图，助手会自己决定调用哪些工具。例如：")
                .font(.callout).foregroundStyle(theme.textSecondary)
            Text("· 看看有哪些请求我 review 的 PR\n· 列出我最近提交的 PR")
                .font(.callout).foregroundStyle(theme.textSecondary)
        }
        .padding(.vertical, 24)
    }

    @ViewBuilder private func row(_ item: AgentChatViewModel.Item) -> some View {
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(item.text)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(theme.accent).foregroundStyle(theme.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .toolCall:
            Label(item.text, systemImage: "wrench.and.screwdriver")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        case .toolResult:
            Text(item.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
        case .assistant:
            MarkdownView(text: item.text)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        case .error:
            Text(item.text)
                .font(.callout).foregroundStyle(theme.danger)
        }
    }

    // MARK: - Confirmation

    private func confirmationBar(_ call: ToolCall) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text("该操作会修改数据：\(call.name)").font(.callout)
                if let args = argsText(call) {
                    Text(args)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            Button("取消") { viewModel.rejectPending() }
            Button("批准执行") { viewModel.approvePending() }
                .buttonStyle(.borderedProminent)
                .tint(theme.danger)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(theme.surface)
    }

    /// Compact JSON of the call's arguments, so the user sees exactly what the
    /// agent wants to act on before approving. `nil` when there are no arguments.
    private func argsText(_ call: ToolCall) -> String? {
        guard let data = try? JSONEncoder().encode(call.arguments),
              let s = String(data: data, encoding: .utf8), s != "{}" else { return nil }
        return s
    }

    // MARK: - Input

    private func inputBar(input: Binding<String>) -> some View {
        HStack(spacing: 8) {
            TextField("描述你的意图…", text: input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .onSubmit { viewModel.send() }

            if viewModel.isRunning {
                ProgressView().controlSize(.small).frame(width: 28)
            } else {
                Button { viewModel.send() } label: { Image(systemName: "arrow.up.circle.fill") }
                    .buttonStyle(.plain)
                    .font(.system(size: 22))
                    .foregroundStyle(theme.accent)
                    .disabled(input.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}
