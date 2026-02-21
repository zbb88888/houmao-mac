import SwiftUI
import AppKit

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
    @FocusState private var isInputFocused: Bool

    private let cornerRadius: CGFloat = 12

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            TextField("", text: $viewModel.inputText,
                      prompt: Text("Type something...")
                        .foregroundColor(.white.opacity(0.35))
                        .font(.system(size: 18, weight: .medium))
            )
            .onSubmit {
                viewModel.submit(historyHandler: {
                    historyViewModel.load()
                    viewModel.toggleHistoryView()
                })
            }
            .textFieldStyle(.plain)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .focused($isInputFocused)
            .padding(.leading, 24)
            .padding(.trailing, 16)
            .frame(height: 56)

            // Results - only after interaction
            if shouldShowResults {
                Divider()
                    .overlay(Color.white.opacity(0.06))
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
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .frame(height: 300)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 680)
        .background(
            ZStack {
                VisualEffectBackground(material: .hudWindow, blendingMode: .behindWindow)
                Color(red: 28/255, green: 28/255, blue: 28/255).opacity(0.75)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.5), radius: 40, y: 12)
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
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isInputFocused = true
                }
            }
        }
        .onChange(of: viewModel.isShowingHistory) {
            if !viewModel.isShowingHistory {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isInputFocused = true
                }
            }
        }
    }

    // MARK: - Window config

    private func configureWindow() {
        guard let window = NSApplication.shared.keyWindow else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.styleMask.remove([.closable, .miniaturizable, .resizable])
        window.appearance = NSAppearance(named: .darkAqua)
    }

    // MARK: - Should show results

    private var shouldShowResults: Bool {
        viewModel.isShowingHistory ||
        viewModel.isLoading ||
        (viewModel.lastUserText != nil && !viewModel.lastUserText!.isEmpty) ||
        (viewModel.lastLLMReply != nil && !viewModel.lastLLMReply!.isEmpty)
    }

    // MARK: - History content

    @ViewBuilder
    private var historyContent: some View {
        HStack {
            Text("Usage History")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Button(action: { viewModel.toggleHistoryView() }) {
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
                    .background(Color.white.opacity(0.05))
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
