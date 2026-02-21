import SwiftUI
import AppKit
import HoumaoCore

// MARK: - Frosted glass (NSVisualEffectView)

struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Main View

struct MainView: View {
    @EnvironmentObject var viewModel: MainViewModel
    @EnvironmentObject var historyViewModel: HistoryViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isInputFocused: Bool
    @ObservedObject private var settings = AppSettings.shared

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
        VStack(spacing: 0) {
            // Search bar
            TextField("", text: $viewModel.inputText,
                      prompt: Text("Type something...")
                        .foregroundColor(.secondary)
                        .font(.system(size: 18, weight: .medium))
            )
            .onSubmit {
                viewModel.submit(onShowHistory: {
                    historyViewModel.load()
                })
            }
            .textFieldStyle(.plain)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.primary)
            .focused($isInputFocused)
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .frame(height: 56)

            // Results - only after interaction
            if shouldShowResults {
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
                }
                .frame(height: 300)
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
            configureWindow()
            isInputFocused = true

            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { _ in
                configureWindow()
                Task { @MainActor in
                    viewModel.clearConversation()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isInputFocused = true
                }
            }
        }
        .onChange(of: viewModel.panel) {
            if viewModel.panel == .none {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
    }

    // MARK: - Window config

    private func configureWindow() {
        let window = NSApplication.shared.keyWindow
            ?? NSApp.windows.first { $0.title != "HotKey Debug" }
        guard let window else { return }
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

    // MARK: - Should show results

    private var shouldShowResults: Bool {
        viewModel.panel != .none
    }

    // MARK: - History content

    @ViewBuilder
    private var historyContent: some View {
        HStack {
            Text("Usage History")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(action: { viewModel.panel = .none }) {
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
                        HStack {
                            if settings.showTimestamp {
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(recordBackground)
                    .cornerRadius(6)
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

    // MARK: - Help content

    @ViewBuilder
    private var helpContent: some View {
        HStack {
            Text("Help")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(action: { viewModel.panel = .none }) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }

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
            helpRow(key: "Cmd + Shift + D", description: "Open debug window")

            Divider().overlay(dividerColor).padding(.vertical, 4)

            Text("Commands")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            helpRow(key: "h", description: "Show this help")
            helpRow(key: "b", description: "Toggle usage history")
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
