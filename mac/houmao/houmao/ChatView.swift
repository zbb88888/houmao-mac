import SwiftUI
import AppKit

// MARK: - Standard chat window content
//
// `ChatView` is the standalone, office-style chat interface hosted in a regular
// resizable / full-screen-capable `NSWindow` (see `AppDelegate.chatWindow`). It
// deliberately does NOT inherit the floating/translucent decorations of the
// minimal input box — it fills the window and uses a standard window material.

struct ChatView: View {
    @Environment(MainViewModel.self) private var viewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isInputFocused: Bool = false
    @State private var chatInputHeight: CGFloat = 34

    private let chatBottomAnchor = "houmao-chat-bottom"

    private var dividerColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.06)
    }

    private var bubbleBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            Divider().overlay(dividerColor)
            chatMessageList
            Divider().overlay(dividerColor)
            chatInputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            VisualEffectBackground(material: .windowBackground, blendingMode: .behindWindow)
        )
        .onExitCommand { viewModel.exitChatMode() }
        .onAppear {
            viewModel.ensureContextWindows()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isInputFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .houmaoChatWindowDidShow)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isInputFocused = true
            }
        }
    }

    // MARK: - Header

    private var chatHeader: some View {
        HStack(spacing: 8) {
            Button(action: { viewModel.renewChat() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Renew")

            if let modelName = viewModel.lastModelName {
                modelBadge(modelName)
                contextRing
            }
            Spacer()
            Button(action: { viewModel.exitChatMode() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Message list

    private var chatMessageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if viewModel.chatStore.messages.isEmpty {
                        chatEmptyState
                    }
                    ForEach(viewModel.chatStore.messages) { message in
                        chatBubble(message).id(message.id)
                    }
                    Color.clear.frame(height: 1).id(chatBottomAnchor)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .frame(maxWidth: 1100, alignment: .center)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: viewModel.chatStore.messages.count) {
                scrollToBottom(proxy)
            }
            .onChange(of: viewModel.chatStore.messages.last?.text) {
                scrollToBottom(proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundColor(.secondary.opacity(0.45))
            Text("Start a conversation")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.secondary)
            Text("⏎ send · ⇧⏎ newline")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(chatBottomAnchor, anchor: .bottom)
        }
    }

    // MARK: - Input bar

    private var chatInputBar: some View {
        @Bindable var viewModel = viewModel
        let canSend = !viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 10) {
            ZStack(alignment: .topLeading) {
                if viewModel.inputText.isEmpty {
                    Text("Message...  ( ⏎ send · ⇧⏎ newline )")
                        .font(.system(size: 15))
                        .foregroundColor(.secondary.opacity(0.8))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                ChatInputField(
                    text: $viewModel.inputText,
                    isFocused: $isInputFocused,
                    measuredHeight: $chatInputHeight,
                    font: .systemFont(ofSize: 15),
                    maxHeight: 120,
                    onSubmit: { viewModel.sendChatTurn() },
                    onUpArrow: viewModel.commandHistory.previous,
                    onDownArrow: viewModel.commandHistory.next,
                    onEscape: { viewModel.exitChatMode() }
                )
                .frame(height: chatInputHeight)
                .padding(.horizontal, 6)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Button(action: {
                if viewModel.isLoading {
                    viewModel.cancelRequest()
                } else {
                    viewModel.sendChatTurn()
                }
            }) {
                Image(systemName: viewModel.isLoading ? "stop.circle.fill" : "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor((canSend || viewModel.isLoading) ? .accentColor : .secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .disabled(!canSend && !viewModel.isLoading)
            .help(viewModel.isLoading ? "Stop" : "Send")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bubble

    private func modelBadge(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.7))
            .cornerRadius(4)
    }

    /// Context-usage ring shown next to the model badge (Claude/Codex style):
    /// the arc fills with the current conversation's estimated token usage
    /// against the model's window. Hovering shows the total window size.
    private var contextRing: some View {
        let window = viewModel.contextWindowTokens
        let used = viewModel.contextUsedTokens
        let fraction = window > 0 ? min(1.0, Double(used) / Double(window)) : 0
        return ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.25), lineWidth: 2)
            if window > 0 {
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(ringColor(fraction),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .frame(width: 13, height: 13)
        .help(window > 0
              ? "上下文窗口 \(window) tokens（已用约 \(used)）"
              : "上下文窗口未知")
    }

    private func ringColor(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.7: return .green
        case ..<0.9: return .orange
        default: return .red
        }
    }

    @ViewBuilder
    private func chatBubble(_ message: Message) -> some View {
        let isUser = message.role == .user
        HStack(alignment: .top, spacing: 8) {
            if isUser {
                Spacer(minLength: 40)
            } else {
                chatAvatar(isUser: false)
            }

            Group {
                if message.text.isEmpty && message.isStreaming {
                    TypingIndicator()
                } else if isUser {
                    // User text is shown as typed (plain, selectable) — block
                    // Markdown decorations would clash with the accent bubble.
                    Text(message.text)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .foregroundColor(.white)
                } else {
                    // Assistant replies get full block-level Markdown rendering.
                    MarkdownView(text: message.text, baseFontSize: 14)
                        .foregroundColor(.primary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isUser ? Color.accentColor : bubbleBackground)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            if isUser {
                chatAvatar(isUser: true)
            } else {
                Spacer(minLength: 40)
            }
        }
    }

    private func chatAvatar(isUser: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isUser ? Color.secondary.opacity(0.25) : Color.accentColor)
            Image(systemName: isUser ? "person.fill" : "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isUser ? .primary : .white)
        }
        .frame(width: 30, height: 30)
    }
}

// MARK: - Typing indicator

/// Three-dot "assistant is typing" animation shown in the streaming bubble
/// before the first token arrives — a standard messenger / AI-client cue.
private struct TypingIndicator: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.32, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .frame(width: 6, height: 6)
                    .foregroundColor(.secondary)
                    .opacity(phase == index ? 1.0 : 0.3)
            }
        }
        .onReceive(timer) { _ in
            phase = (phase + 1) % 3
        }
    }
}
