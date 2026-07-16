import SwiftUI
import Observation

/// State for the one shared Markdown editor window. Parametric so any view can
/// reuse the same editor: it carries the working `text`, a display `title`, and
/// the `onSave` sink that decides where the text goes (a Do item, a note, …).
@MainActor
@Observable
final class MarkdownEditorModel {
    var text: String
    let title: String
    private let onSave: (String) -> Void

    init(title: String, text: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.text = text
        self.onSave = onSave
    }

    /// Hand the current text to the caller's sink. Called when the editor is
    /// committed (save button) or the window closes.
    func save() { onSave(text) }
}

/// houmao's single, general-purpose Markdown editor. Content-agnostic: it edits
/// plain Markdown text and reports it back via the model's `onSave`. Both the
/// save-and-close button and closing the window persist (there is no discard
/// path — closing means saving, mirroring the app's inline-edit behaviour).
struct MarkdownEditorView: View {
    @Bindable var model: MarkdownEditorModel

    @FocusState private var focused: Bool
    private var theme: Theme { AppTheme.current }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            TextEditor(text: $model.text)
                .font(.system(size: 14))
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .padding(12)
                .focused($focused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        .onAppear { focused = true }
    }

    private var header: some View {
        HStack {
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            // Save-and-close: closing the window also saves, so this is the
            // explicit affordance for "done". Routed through a notification so
            // the app delegate owns the single editor window's lifecycle.
            Button {
                NotificationCenter.default.post(name: .houmaoCommitEditor, object: nil)
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)
            .help("保存并关闭（关闭窗口同样保存）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}
