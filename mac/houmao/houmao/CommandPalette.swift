import SwiftUI

/// Persisted recent search terms for the unified command palette (global across
/// pages — the box is one unified search). Most-recent-first, case-insensitively
/// deduped, capped. Backed by `UserDefaults` so it survives relaunches.
enum SearchHistoryStore {
    private static let key = "houmao.search.history"
    private static let limit = 20

    static func list() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    static func record(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        var items = list().filter { $0.caseInsensitiveCompare(t) != .orderedSame }
        items.insert(t, at: 0)
        if items.count > limit { items = Array(items.prefix(limit)) }
        UserDefaults.standard.set(items, forKey: key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// The context a window gives its command palette: the page's display name, an
/// optional live search hook (filters the page's content), and optional
/// page-specific help lines. Pages without a search hook get command/help only.
struct PaletteContext {
    var pageName: String = "本页"
    var onSearch: (@MainActor (String) -> Void)? = nil
    var helpLines: [String] = []
}

/// A ⌘K command palette pinned near the top of the window (so it doesn't cover
/// the body). One box, three modes by prefix:
/// - no prefix → **search** the current page (via `context.onSearch`);
/// - `/` → **command** mode: fuzzy-pick a page to jump to;
/// - `/h` → **help** for the current window.
struct CommandPaletteView: View {
    let context: PaletteContext
    let onClose: () -> Void
    private var theme: Theme { AppTheme.current }

    @State private var query = ""
    /// Recent searches, loaded fresh each time the palette opens (the view is
    /// recreated on every open, so the box always starts clean).
    @State private var history: [String] = SearchHistoryStore.list()
    /// Cursor into `history` for ↑/↓ recall (-1 = the empty, freshly-typed box).
    @State private var historyCursor = -1
    @FocusState private var focused: Bool

    private var isCommandMode: Bool { query.hasPrefix("/") }
    private var commandTerm: String {
        String(query.dropFirst()).trimmingCharacters(in: .whitespaces)
    }
    private var isHelp: Bool {
        let t = commandTerm.lowercased()
        return t == "h" || t == "help" || t == "帮助"
    }
    private var matchedCommands: [PanelDestination] {
        PanelDestination.all.filter { $0.matches(commandTerm) }
    }

    var body: some View {
        VStack(spacing: 0) {
            input
            Divider().overlay(theme.divider)
            results
        }
        .frame(width: 520)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.divider))
        .shadow(color: .black.opacity(0.18), radius: 20, y: 8)
        .onAppear { focused = true }
    }

    // MARK: - Input

    private var input: some View {
        HStack(spacing: 8) {
            Image(systemName: isCommandMode ? "chevron.right" : "magnifyingglass")
                .foregroundStyle(theme.textSecondary)
            TextField("搜索「\(context.pageName)」· 输入 / 执行命令 · /h 帮助", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(theme.textPrimary)
                .focused($focused)
                .onChange(of: query) { _, v in liveSearch(v) }
                .onSubmit(runPrimary)
                .onExitCommand(perform: onClose)
                // ↑/↓ recall recent searches into the box (search mode only).
                .onKeyPress(.upArrow) {
                    guard !isCommandMode, !history.isEmpty else { return .ignored }
                    historyUp()
                    return .handled
                }
                .onKeyPress(.downArrow) {
                    guard !isCommandMode, historyCursor >= 0 else { return .ignored }
                    historyDown()
                    return .handled
                }
        }
        .padding(14)
    }

    // MARK: - Results

    @ViewBuilder private var results: some View {
        if isHelp {
            helpView
        } else if isCommandMode {
            commandRows(matchedCommands, empty: "无匹配命令")
        } else if query.isEmpty {
            emptyState
        } else {
            searchStatus
        }
    }

    /// Empty box = a clean start: pick a recent search (if the page supports
    /// search) or jump to a page; typing filters live.
    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 0) {
            if context.onSearch != nil && !history.isEmpty {
                historySection
                Divider().overlay(theme.divider)
            }
            commandRows(PanelDestination.all, empty: "")
            tip
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("最近搜索")
                    .font(.caption).foregroundStyle(theme.textTertiary)
                Spacer()
                Button("清除") {
                    SearchHistoryStore.clear()
                    history = []
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 2)

            ForEach(Array(history.prefix(6)), id: \.self) { term in
                Button { runSearch(term) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .frame(width: 22)
                            .foregroundStyle(theme.textSecondary)
                        Text(term).foregroundStyle(theme.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder private func commandRows(_ items: [PanelDestination], empty: String) -> some View {
        if items.isEmpty {
            Text(empty)
                .font(.callout).foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        } else {
            VStack(spacing: 0) {
                ForEach(items) { item in
                    Button { run(item) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol)
                                .frame(width: 22)
                                .foregroundStyle(theme.textSecondary)
                            Text(item.title).foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text("/\(item.keywords.first ?? "")")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.textTertiary)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var searchStatus: some View {
        HStack(spacing: 8) {
            if context.onSearch != nil {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .foregroundStyle(theme.textSecondary)
                Text("在「\(context.pageName)」中筛选：\(query)")
                    .foregroundStyle(theme.textSecondary)
            } else {
                Image(systemName: "exclamationmark.circle")
                    .foregroundStyle(theme.textSecondary)
                Text("「\(context.pageName)」暂不支持页内搜索")
                    .foregroundStyle(theme.textSecondary)
            }
            Spacer()
        }
        .font(.callout)
        .padding(14)
    }

    private var tip: some View {
        Text("直接输入 = 搜索本页 · ↑↓ 历史 · “/” 命令 · “/h” 帮助 · Esc 关闭")
            .font(.caption).foregroundStyle(theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.bottom, 12).padding(.top, 2)
    }

    @ViewBuilder private var helpView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("帮助 · \(context.pageName)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            helpLine("搜索本页", "直接输入关键字，实时筛选当前页内容")
            helpLine("历史", "↑ / ↓ 调取最近的搜索；空框内也可点选「最近搜索」")
            helpLine("命令 / 跳转", "输入 “/” 后接页面名（如 /mail、/待办）跳到对应功能页")
            helpLine("帮助", "输入 “/h” 显示本帮助")
            ForEach(context.helpLines, id: \.self) { line in
                Text(line).font(.callout).foregroundStyle(theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func helpLine(_ head: String, _ body: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(head).font(.callout.weight(.medium)).foregroundStyle(theme.textPrimary)
                .frame(width: 72, alignment: .leading)
            Text(body).font(.callout).foregroundStyle(theme.textSecondary)
        }
    }

    // MARK: - Actions

    /// Live-filter the page while typing free text; typing a command resets any
    /// page filter first.
    private func liveSearch(_ text: String) {
        guard let onSearch = context.onSearch else { return }
        onSearch(text.hasPrefix("/") ? "" : text)
    }

    private func runPrimary() {
        if isCommandMode {
            if !isHelp, let first = matchedCommands.first { run(first) }
            // help mode: leave the palette open showing help.
        } else {
            // Commit the search: record it, apply it, and close with a clean box
            // (an empty submit clears the page filter — a manual "clear" gesture).
            runSearch(query)
        }
    }

    /// Apply `term` to the page, remember it, then close with the box cleared.
    /// An empty `term` clears the current page filter.
    private func runSearch(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        if let onSearch = context.onSearch {
            onSearch(t)
            SearchHistoryStore.record(t)
        }
        query = ""
        onClose()
    }

    /// Recall an older search into the box (↑). Setting `query` re-filters live.
    private func historyUp() {
        historyCursor = min(historyCursor + 1, history.count - 1)
        query = history[historyCursor]
    }

    /// Step back toward the newer/empty box (↓).
    private func historyDown() {
        historyCursor -= 1
        query = historyCursor < 0 ? "" : history[historyCursor]
    }

    private func run(_ item: PanelDestination) {
        NotificationCenter.default.post(name: item.notification, object: nil)
        onClose()
    }
}
