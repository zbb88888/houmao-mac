import SwiftUI
import AppKit

// MARK: - Key event handler for Settings window

struct SettingsKeyHandler: NSViewRepresentable {
    var onEscape: () -> Void
    var onReturn: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.onEscape = onEscape
        view.onReturn = onReturn
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? KeyView else { return }
        view.onEscape = onEscape
        view.onReturn = onReturn
    }

    class KeyView: NSView {
        var onEscape: (() -> Void)?
        var onReturn: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.window == NSApp.keyWindow else { return event }

                switch event.keyCode {
                case 53: // ESC
                    self.onEscape?()
                    return nil
                case 36, 76: // Return / Numpad Enter
                    // Let text fields handle Return themselves
                    if self.window?.firstResponder is NSTextView { return event }
                    self.onReturn?()
                    return nil
                default:
                    return event
                }
            }
        }

        override func removeFromSuperview() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            super.removeFromSuperview()
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    private var settings = AppSettings.shared

    @AppStorage("selectToCopyEnabled") private var copyOnSelection = false

    @State private var editingProviderID: UUID?
    @State private var providerName = ""
    @State private var providerURL = ""
    @State private var providerApiKey = ""
    @State private var providerModels = ""   // Comma-separated model IDs
    @State private var providerError = ""

    /// 图标列固定宽度，保证竖向对齐
    private let iconWidth: CGFloat = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Copy on Selection", isOn: $copyOnSelection)
                .onChange(of: copyOnSelection) { _, newValue in
                    SelectToCopyManager.shared.isEnabled = newValue
                }

            Divider()

            HStack {
                Button(action: { editingProviderID = UUID() }) {
                    Image(systemName: "plus")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .help("Add provider")
                Spacer()
            }

            ForEach(Array(settings.providers.enumerated()), id: \.element.id) { index, provider in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(provider.name)
                            .font(.system(size: 13, weight: .semibold))
                        if index == 0 {
                            Text("default")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.accentColor.opacity(0.7))
                                .cornerRadius(3)
                        }
                        Spacer()
                        if index > 0 {
                            Button {
                                settings.moveProviderToTop(at: index)
                            } label: {
                                Image(systemName: "arrow.up.to.line")
                                    .frame(width: iconWidth)
                            }
                            .buttonStyle(.borderless)
                            .help("Set as default")
                        }
                        Button {
                            providerName = provider.name
                            providerURL = provider.apiHost
                            providerApiKey = provider.apiKey
                            providerModels = provider.models.joined(separator: ", ")
                            editingProviderID = provider.id
                            providerError = ""
                        } label: {
                            Image(systemName: "pencil")
                                .frame(width: iconWidth)
                        }
                        .buttonStyle(.borderless)
                        .help("Edit")
                        Button(role: .destructive) {
                            settings.providers.removeAll { $0.id == provider.id }
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: iconWidth)
                        }
                        .buttonStyle(.borderless)
                    }
                    Text(provider.models.joined(separator: ", "))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .padding(8)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(6)
            }

            if editingProviderID != nil {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Name * (e.g. OpenAI, DeepSeek, Local)", text: $providerName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveProvider() }
                    TextField("URL * (e.g. https://api.openai.com)", text: $providerURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveProvider() }
                    TextField("Models * (comma-separated, e.g. gpt-4o, gpt-4o-mini)", text: $providerModels)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveProvider() }
                    SecureField("API Key (optional)", text: $providerApiKey)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveProvider() }
                    if !providerError.isEmpty {
                        Text(providerError)
                            .font(.system(size: 11))
                            .foregroundColor(.red)
                    }
                    HStack {
                        Button("Save") { saveProvider() }
                        Button("Cancel") { resetForm() }
                    }
                }
                .padding(.top, 4)
            }
        }
        .toggleStyle(.checkbox)
        .padding(24)
        .frame(width: 480, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("")
        .background(
            SettingsKeyHandler(
                onEscape: {
                    if editingProviderID != nil {
                        resetForm()
                    } else {
                        NSApp.keyWindow?.close()
                    }
                },
                onReturn: {
                    if editingProviderID != nil {
                        saveProvider()
                    } else {
                        NSApp.keyWindow?.close()
                    }
                }
            )
        )
    }

    private func saveProvider() {
        let name = providerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = providerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = providerApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = providerModels
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Validate
        if let error = validateProvider(name: name, url: url, models: models) {
            providerError = error
            return
        }

        // Save or update
        if let id = editingProviderID,
           let i = settings.providers.firstIndex(where: { $0.id == id }) {
            settings.providers[i] = Provider(id: id, name: name, apiHost: url, apiKey: apiKey, models: models)
        } else {
            settings.providers.append(Provider(name: name, apiHost: url, apiKey: apiKey, models: models))
        }
        resetForm()
    }

    private func validateProvider(name: String, url: String, models: [String]) -> String? {
        guard !name.isEmpty else { return "Name is required." }
        guard !url.isEmpty else { return "URL is required." }
        guard !models.isEmpty else { return "At least one model is required." }
        guard URL(string: url) != nil else { return "Invalid URL." }

        // Check duplicate provider name
        let isDuplicate = settings.providers.contains { provider in
            provider.id != editingProviderID &&
            provider.name.caseInsensitiveCompare(name) == .orderedSame
        }
        return isDuplicate ? "A provider named \"\(name)\" already exists." : nil
    }

    private func resetForm() {
        providerName = ""
        providerURL = ""
        providerApiKey = ""
        providerModels = ""
        providerError = ""
        editingProviderID = nil
    }
}
