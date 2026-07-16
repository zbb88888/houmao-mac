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

    @FocusState private var editorFocused: Bool
    @FocusState private var searchFocused: Bool
    @State private var query: String = ""
    private var theme: Theme { AppTheme.current }

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var isHelp: Bool { trimmedQuery == "/h" }
    private var isCheck: Bool { trimmedQuery == "/check" }
    /// The assist overlay shows only while the search box is focused and holds a
    /// query — it never covers the editor during normal typing.
    private var showPanel: Bool { searchFocused && !trimmedQuery.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            TextEditor(text: $model.text)
                .font(.system(size: 14))
                .lineSpacing(2)
                .scrollContentBackground(.hidden)
                .padding(12)
                .focused($editorFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if showPanel { assistPanel.padding(10) }
                }
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        .onAppear { editorFocused = true }
    }

    // MARK: Header (title · search · save)

    private var header: some View {
        HStack(spacing: 10) {
            Text(model.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Spacer()
            searchField
            // AI fix: send the whole document to the chat with a fixed
            // "repair Markdown format" prompt; the fixed text comes back as a
            // chat bubble for the user to copy back in.
            Button {
                AppDelegate.shared?.mainViewModel.fixMarkdownForChat(model.text)
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            .buttonStyle(.plain)
            .help("AI 修复 Markdown 格式（结果发到聊天气泡，复制回来）")
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

    /// Minimal magnifier box, doubling as `/h` Markdown-help and full-text search.
    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            TextField("搜索 · /h · /check", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .frame(width: 150)
                .focused($searchFocused)
                .onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.textSecondary.opacity(0.6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(theme.surface, in: Capsule())
    }

    // MARK: Assist panel (help / search results)

    @ViewBuilder private var assistPanel: some View {
        Group {
            if isHelp { helpPanel }
            else if isCheck { checkPanel }
            else { resultsPanel }
        }
        .frame(width: 300)
        .background(theme.background)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.divider))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    /// `/check` — static Markdown format lint results (read-only helper).
    @ViewBuilder private var checkPanel: some View {
        let issues = MarkdownLint.check(model.text)
        VStack(alignment: .leading, spacing: 0) {
            Text(issues.isEmpty ? "格式良好 ✓" : "\(issues.count) 处格式问题")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            if !issues.isEmpty {
                Divider().overlay(theme.divider)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(issue.line)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(theme.textSecondary)
                                    .frame(minWidth: 26, alignment: .trailing)
                                Text(issue.message)
                                    .font(.system(size: 12))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    /// Lines of the document containing the query (case-insensitive), capped so a
    /// huge document can't produce an unbounded list. Read-only helper: the plain
    /// `TextEditor` can't move the caret, so this surfaces where matches are.
    private var matchingLines: [(line: Int, text: String)] {
        let q = trimmedQuery
        guard !q.isEmpty else { return [] }
        var out: [(Int, String)] = []
        for (i, raw) in model.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = String(raw)
            if line.range(of: q, options: .caseInsensitive) != nil {
                out.append((i + 1, line.trimmingCharacters(in: .whitespaces)))
                if out.count >= 100 { break }
            }
        }
        return out
    }

    @ViewBuilder private var resultsPanel: some View {
        let hits = matchingLines
        VStack(alignment: .leading, spacing: 0) {
            Text(hits.isEmpty ? "无匹配" : "\(hits.count) 行匹配")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            if !hits.isEmpty {
                Divider().overlay(theme.divider)
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(hit.line)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(theme.textSecondary)
                                    .frame(minWidth: 26, alignment: .trailing)
                                Text(hit.text.isEmpty ? " " : hit.text)
                                    .font(.system(size: 12))
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
    }

    private var helpPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(Self.helpRows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        Text(row.syntax)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(theme.textPrimary)
                            .frame(width: 118, alignment: .leading)
                        Text(row.desc)
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxHeight: 300)
    }

    private static let helpRows: [(syntax: String, desc: String)] = [
        ("# 标题", "一到六级：# … ######"),
        ("**粗体**", "加粗"),
        ("*斜体*", "斜体"),
        ("- 项", "无序列表（或 *）"),
        ("1. 项", "有序列表"),
        ("> 引用", "块引用"),
        ("`代码`", "行内代码"),
        ("``` 代码 ```", "代码块（三反引号起止）"),
        ("[文字](URL)", "超链接"),
        ("![说明](图片)", "图片"),
        ("| A | B |", "表格；下一行 | --- | --- |"),
        ("---", "分隔线"),
    ]
}
