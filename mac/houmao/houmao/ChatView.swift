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
    @State private var isInputFocused: Bool = false
    @State private var chatInputHeight: CGFloat = 34
    @State private var windowSize: CGSize = .zero
    /// Whether the scroll view is currently parked at the bottom. Streaming
    /// tokens only auto-scroll while this is true, so the view stops yanking
    /// downward once the user scrolls up to read (auto-follow resumes when they
    /// scroll back to the bottom).
    @State private var isPinnedToBottom: Bool = true

    private let chatBottomAnchor = "houmao-chat-bottom"

    private var theme: Theme { AppTheme.current }

    /// Golden-ratio adaptive cap for the input box: it grows with content up to
    /// the minor golden segment (≈0.382) of the window height, so a filled input
    /// leaves the major segment (≈0.618) for messages. Falls back to 132 before
    /// the window height is measured.
    private var inputMaxHeight: CGFloat {
        windowSize.height > 0 ? windowSize.height * 0.382 : 132
    }

    /// Golden-ratio width for the input bar: the major segment (≈0.618) of the
    /// window width, centered, leaving symmetric ≈0.191 dim margins on each side.
    /// Falls back to 920 before the window width is measured.
    private var inputMaxWidth: CGFloat {
        windowSize.width > 0 ? windowSize.width * 0.618 : 920
    }

    /// Bottom spacer reserved while a mail analysis is pinned to the top, so the
    /// pinned header bubble has a full viewport of scrollable content beneath it
    /// and can actually reach the top even when the reply is short/empty.
    private var topReserveHeight: CGFloat {
        guard viewModel.topAnchorMessageID != nil else { return 0 }
        return windowSize.height > 0 ? windowSize.height : 800
    }

    var body: some View {
        VStack(spacing: 0) {
            chatMessageList
            Divider().overlay(theme.divider)
            chatInputBar
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                    windowSize = size
                }
            }
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
        .preferredColorScheme(.light)
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
                    // While a mail analysis is pinned to the top, reserve a full
                    // viewport below it so it can actually scroll to the top even
                    // before the reply streams in (otherwise the scroll view hits
                    // its bottom and the bubble never reaches the top).
                    if topReserveHeight > 0 {
                        Color.clear.frame(height: topReserveHeight)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 18)
                .frame(maxWidth: 1100, alignment: .center)
                .frame(maxWidth: .infinity)
            }
            .onScrollGeometryChange(for: Bool.self) { geo in
                // "At bottom" within a small slack, so ordinary rounding while
                // streaming still counts as pinned.
                geo.contentOffset.y >= geo.contentSize.height - geo.containerSize.height - 24
            } action: { _, atBottom in
                isPinnedToBottom = atBottom
            }
            .onChange(of: viewModel.chatStore.messages.count) {
                // A mail analysis parks its header bubble at the TOP of the
                // viewport (history above the fold; a full-viewport bottom spacer
                // reserves room so it can actually reach the top). Any other new
                // turn re-pins to the bottom as usual.
                if viewModel.topAnchorMessageID != nil {
                    applyTopAnchor(proxy)
                } else {
                    isPinnedToBottom = true
                    scrollToBottom(proxy)
                }
            }
            .onChange(of: viewModel.chatStore.messages.last?.text) {
                // Follow streaming tokens only while pinned, and without the
                // per-token animation (overlapping animated jumps were the jitter).
                guard isPinnedToBottom else { return }
                proxy.scrollTo(chatBottomAnchor, anchor: .bottom)
            }
            .onReceive(NotificationCenter.default.publisher(for: .houmaoChatWindowDidShow)) { _ in
                // A freshly created window renders at the top and never fires the
                // message-count onChange, so honor the top anchor here too.
                applyTopAnchor(proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chatEmptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 34))
                .foregroundColor(theme.textSecondary.opacity(0.45))
            Text("Start a conversation")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(theme.textSecondary)
            Text("⏎ send · ⇧⏎ newline")
                .font(.system(size: 11))
                .foregroundColor(theme.textSecondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 96)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(chatBottomAnchor, anchor: .bottom)
        }
    }

    /// Park the mail-analysis header bubble at the TOP of the viewport (and stop
    /// bottom auto-follow so streamed tokens don't yank it down). The full-viewport
    /// bottom spacer (`topReserveHeight`) guarantees enough content below it to
    /// actually reach the top even before the reply streams in. No-op when no top
    /// anchor is requested. The anchor stays set until the next ordinary turn (the
    /// view model clears it), so back-to-back analyses each re-pin.
    private func applyTopAnchor(_ proxy: ScrollViewProxy) {
        guard let id = viewModel.topAnchorMessageID else { return }
        isPinnedToBottom = false
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(id, anchor: .top)
            }
        }
    }

    // MARK: - Input bar

    private var chatInputBar: some View {
        @Bindable var viewModel = viewModel
        return HStack(alignment: .bottom, spacing: 10) {
            // Left: display-only status (model + context-usage ring).
            if let modelName = viewModel.lastModelName {
                HStack(spacing: 8) {
                    modelBadge(modelName)
                    contextRing
                }
                .padding(.bottom, 8)
            }

            ZStack(alignment: .topLeading) {
                ChatInputField(
                    text: $viewModel.inputText,
                    isFocused: $isInputFocused,
                    measuredHeight: $chatInputHeight,
                    font: .systemFont(ofSize: 15),
                    maxHeight: inputMaxHeight,
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
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            // Right: stop (only while generating) + new-conversation. There is no
            // submit button — Enter sends (⇧⏎ inserts a newline).
            HStack(spacing: 10) {
                if viewModel.isLoading {
                    Button(action: { viewModel.cancelRequest() }) {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(theme.accent)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                }
                Button(action: {
                    NotificationCenter.default.post(name: .houmaoEnterMailWindow, object: nil)
                }) {
                    Image(systemName: "envelope")
                        .font(.system(size: 16))
                        .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("邮件清理")
                Button(action: {
                    NotificationCenter.default.post(name: .houmaoEnterPRWindow, object: nil)
                }) {
                    Image(systemName: "arrow.triangle.pull")
                        .font(.system(size: 16))
                        .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("我的 PR")
                Button(action: {
                    NotificationCenter.default.post(name: .houmaoEnterIssueWindow, object: nil)
                }) {
                    Image(systemName: "smallcircle.filled.circle")
                        .font(.system(size: 16))
                        .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("我的 Issue")
                Button(action: { viewModel.renewChat() }) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16))
                        .foregroundColor(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("新对话")
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: inputMaxWidth)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Bubble

    private func modelBadge(_ name: String) -> some View {
        Text(name)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(theme.onAccent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(theme.accent.opacity(0.7))
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
                .stroke(theme.divider, lineWidth: 2)
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
                        .foregroundColor(theme.onAccent)
                } else {
                    // Assistant replies get full block-level Markdown rendering.
                    MarkdownView(text: message.text, baseFontSize: 14)
                        .foregroundColor(theme.textPrimary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isUser ? theme.accent : theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contextMenu {
                if !message.text.isEmpty {
                    Button("复制") { copyToPasteboard(message.text) }
                }
                if !isUser && viewModel.canDeepenMail(message.id) {
                    Button("深入") { viewModel.deepenMail(message.id) }
                }
            }

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
                .fill(isUser ? theme.divider : theme.accent)
            Image(systemName: isUser ? "person.fill" : "sparkles")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(isUser ? theme.textPrimary : theme.onAccent)
        }
        .frame(width: 30, height: 30)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
