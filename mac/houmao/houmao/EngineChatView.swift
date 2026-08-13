import SwiftUI

/// 引擎聊天窗最小 UI：状态条 + 气泡 transcript + 输入栏。纯渲染引擎回传的态。
struct EngineChatView: View {
    @Bindable var model: EngineChatViewModel
    private var theme: Theme { AppTheme.current }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            transcript
            Divider()
            inputBar
        }
        .background(theme.background)
        .onAppear { model.onAppear() }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isConnected ? theme.success : theme.textTertiary)
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            Spacer()
            if !model.lines.isEmpty {
                Button { model.clear() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(theme.textTertiary)
                    .help("清空当前显示")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.lines) { line in
                        bubble(line).id(line.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: model.lines.last?.text) { _, _ in
                if let last = model.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ line: EngineChatViewModel.Line) -> some View {
        switch line.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(line.text)
                    .padding(10)
                    .background(theme.accent)
                    .foregroundStyle(theme.onAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        case .assistant:
            HStack {
                MarkdownView(text: line.text)
                    .padding(10)
                    .background(theme.surface)
                    .foregroundStyle(theme.textPrimary)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Spacer(minLength: 40)
            }
        case .system:
            Text(line.text)
                .font(.caption)
                .foregroundStyle(theme.danger)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("发消息给引擎…", text: $model.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .padding(8)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onSubmit { model.send() }
            Button { model.send() } label: { Image(systemName: "arrow.up.circle.fill") }
                .buttonStyle(.borderless)
                .font(.title2)
                .foregroundStyle(model.isBusy ? theme.textTertiary : theme.accent)
                .disabled(model.isBusy)
        }
        .padding(10)
    }
}
