import SwiftUI
import AppKit

// MARK: - Frosted glass (NSVisualEffectView)

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = VisualEffectBackgroundView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private class VisualEffectBackgroundView: NSVisualEffectView {
    private var isWindowConfigured = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window, !isWindowConfigured else { return }
        isWindowConfigured = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove([.closable, .miniaturizable, .resizable])
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }
}

// MARK: - Main View

struct MainView: View {
    @Environment(MainViewModel.self) private var viewModel
    @Environment(HistoryViewModel.self) private var historyViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var isInputFocused: Bool = false
    private var settings = AppSettings.shared
    @AppStorage("showTimestamp") private var showTimestamp = false
    @AppStorage("showAppSwitch") private var showAppSwitch = false

    private let cornerRadius: CGFloat = 12

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    // Adaptive colors
    private var borderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.1)
            : Color.black.opacity(0.1)
    }

    private var dividerColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.06)
            : Color.black.opacity(0.06)
    }

    private var recordBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.black.opacity(0.04)
    }

    var body: some View {
        @Bindable var viewModel = viewModel

        VStack(spacing: 0) {
            // Search bar
            HStack(spacing: 8) {
                IMETextField(
                    text: $viewModel.inputText,
                    isFocused: $isInputFocused,
                    placeholder: "zzz...",
                    font: .systemFont(ofSize: 18, weight: .medium),
                    onSubmit: { viewModel.submit() },
                    onUpArrow: viewModel.commandHistory.previous,
                    onDownArrow: viewModel.commandHistory.next
                )

                Button(action: openFilePicker) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Attach files")
            }
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .frame(height: 56)

            // Attachment strip
            if !viewModel.attachments.isEmpty {
                attachmentStrip
            }

            // Results - only after interaction
            if viewModel.panel != .none {
                Divider()
                    .overlay(dividerColor)
                    .padding(.horizontal, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        switch viewModel.panel {
                        case .help:
                            helpContent
                        case .history:
                            historyContent
                        case .chat:
                            chatContent
                        case .none:
                            EmptyView()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                    .textSelection(.enabled)
                }
                .frame(maxHeight: 400)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 680)
        .background(
            VisualEffectBackground(material: .popover, blendingMode: .behindWindow)
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.3), radius: 40, y: 12)
        .padding(40)
        .onExitCommand {
            NSApplication.shared.keyWindow?.orderOut(nil)
        }
        .onAppear {
            isInputFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .houmaoWindowDidShow)) { _ in
            viewModel.clearConversation()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isInputFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isInputFocused = true
            }
        }
        .onChange(of: viewModel.panel) {
            if viewModel.panel == .history {
                historyViewModel.load()
            }
            if viewModel.panel == .none {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
    }

    // MARK: - File picker

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else { return }
            DispatchQueue.main.async {
                for url in panel.urls {
                    viewModel.addFile(url: url)
                }
            }
        }
    }

    // MARK: - Attachment strip

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(viewModel.attachments) { att in
                    ZStack(alignment: .topTrailing) {
                        attachmentThumbnail(att)

                        Button(action: {
                            viewModel.removeAttachment(id: att.id)
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundColor(.white)
                                .background(Circle().fill(Color.black.opacity(0.5)))
                        }
                        .buttonStyle(.plain)
                        .offset(x: 4, y: -4)
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 6)
        }
        .frame(height: 60)
    }

    @ViewBuilder
    private func attachmentThumbnail(_ att: Attachment) -> some View {
        switch att.content {
        case .image(let nsImage, _):
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        case .audio(let name, _, _):
            VStack(spacing: 4) {
                Image(systemName: "waveform")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                Text(name)
                    .font(.system(size: 8))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(width: 48, height: 48)
            .background(recordBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    // MARK: - Helpers

    private func panelHeader(title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(action: { viewModel.panel = .none }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - History content

    @ViewBuilder
    private var historyContent: some View {
        panelHeader(title: "Usage History")

        if historyViewModel.records.isEmpty {
            Text("No history yet")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .padding(.top, 16)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            let filtered = showAppSwitch
                ? historyViewModel.records
                : historyViewModel.records.filter { !$0.text.hasPrefix("[Switch]") }

            LazyVStack(alignment: .leading, spacing: 6) {
                ForEach(filtered) { record in
                    recordRow(record)
                }
            }
            .padding(.vertical, 8)

            Button("Clear All") {
                historyViewModel.clearAll()
            }
            .font(.system(size: 12))
            .foregroundColor(.red.opacity(0.8))
            .padding(.top, 4)
        }
    }

    private func recordRow(_ record: UsageRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if showTimestamp {
                    Text(dateFormatter.string(from: record.timestamp))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Text(record.appName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            Text(record.text)
                .font(.system(size: 12))
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(recordBackground)
        .cornerRadius(6)
    }

    // MARK: - Help content

    @ViewBuilder
    private var helpContent: some View {
        panelHeader(title: "Help")

        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcuts")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            helpRow(key: "Double Option", description: "Show / Hide window")
            helpRow(key: "Esc", description: "Hide window")
            helpRow(key: "Cmd + K", description: "Clear conversation")
            helpRow(key: "Cmd + B", description: "Toggle usage history")
            helpRow(key: "Cmd + L", description: "Clear all history")
            helpRow(key: "Cmd + W", description: "Hide window")

            Divider().overlay(dividerColor).padding(.vertical, 4)

            Text("Commands")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            helpRow(key: "h", description: "Show this help")
            helpRow(key: "b", description: "Toggle usage history")
            helpRow(key: "@name msg", description: "Send message to a worker")

            if !settings.workers.isEmpty {
                Divider().overlay(dividerColor).padding(.vertical, 4)

                Text("Workers")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)

                ForEach(settings.workers) { worker in
                    helpRow(key: "@\(worker.name)", description: worker.url)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func helpRow(key: String, description: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(recordBackground)
                .cornerRadius(4)
            Text(description)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Chat content

    private let textSize: CGFloat = 13

    @ViewBuilder
    private var chatContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let lastWorkerName = viewModel.lastWorkerName {
                Text("@\(lastWorkerName)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.7))
                    .cornerRadius(4)
            }

            if let lastUserText = viewModel.lastUserText, !lastUserText.isEmpty {
                Text(makeAttributedText("Q: ", lastUserText))
            }

            if viewModel.isLoading {
                HStack(alignment: .top, spacing: 8) {
                    Text("A:")
                        .font(.system(size: textSize, weight: .semibold))
                        .foregroundColor(.secondary)
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                    Text("Thinking...")
                        .font(.system(size: textSize))
                        .foregroundColor(.secondary)
                }
            } else if let lastLLMReply = viewModel.lastLLMReply {
                Text(makeAttributedText("A: ", lastLLMReply))
            }
        }
    }

    private func makeAttributedText(_ label: String, _ content: String) -> AttributedString {
        var result = AttributedString(label)
        result.font = .system(size: textSize, weight: .semibold)
        result.foregroundColor = .secondary

        var text = AttributedString(content)
        text.font = .system(size: textSize)

        result.append(text)
        return result
    }
}
