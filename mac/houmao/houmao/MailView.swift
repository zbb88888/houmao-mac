import SwiftUI
import AppKit

/// The `/mail` cleanup page (Phase 6): review Gmail grouped by category → cluster
/// and batch-move the selection to Trash. Rendered in a standalone window,
/// mirroring the `/chat` window shell.
struct MailView: View {
    @Environment(MailViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    @State private var expanded: Set<UUID> = []
    @State private var showTagEditor = false
    @State private var tagDraft = ""
    @State private var showHelp = false
    /// The search box text, decoupled from `viewModel.searchFilter` so typing a
    /// command like `/h` doesn't leak into the local filter.
    @State private var searchText = ""
    /// Whether the search box is revealed (tap the magnifier to toggle).
    @State private var showSearch = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            content
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        .sheet(isPresented: $showTagEditor) { tagEditor }
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            // Action group on the left (nearest the row checkboxes), ordered by
            // use frequency: delete → AI → read → edit → refresh.
            if viewModel.isMutating {
                ProgressView().controlSize(.small)
            }

            Button {
                Task { await viewModel.submitCleanup() }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.danger)
            .help("删除（移入废纸篓）")
            .accessibilityLabel("删除，移入废纸篓")
            .disabled(viewModel.selectedCount == 0 || viewModel.isMutating)

            if viewModel.canAnalyze {
                Button {
                    Task { await viewModel.analyzeSelected() }
                } label: {
                    Image(systemName: "sparkles")
                }
                .help("AI 分析选中邮件（整簇按时间线）")
                .accessibilityLabel("AI 分析选中邮件")
                .disabled(viewModel.selectedCount == 0 || viewModel.isMutating)
            }

            Button {
                Task { await viewModel.markRead() }
            } label: {
                Image(systemName: "envelope.open")
            }
            .help("标记已读")
            .accessibilityLabel("标记已读")
            .disabled(viewModel.selectedCount == 0 || viewModel.isMutating)

            Button {
                showTagEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .help("编辑自定义分类标签")
            .accessibilityLabel("编辑自定义分类标签")

            Button {
                Task { await viewModel.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")
            .accessibilityLabel("刷新")
            .disabled(isBusy)

            Spacer()

            if showSearch {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                    TextField("在已加载邮件中搜索 · 输入 /h 查看帮助", text: $searchText)
                        .textFieldStyle(.plain)
                        .foregroundStyle(theme.textPrimary)
                        .focused($searchFocused)
                        .onChange(of: searchText) { _, newValue in applySearchFilter(newValue) }
                        .onSubmit { runSearch() }
                    Button { closeSearch() } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.textSecondary)
                    .help("关闭搜索")
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.divider))
                .frame(maxWidth: 340)
                .popover(isPresented: $showHelp, arrowEdge: .bottom) { helpPopover }
            } else {
                Button { openSearch() } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .help("搜索已加载邮件（输入 /h 查看帮助）")
                .accessibilityLabel("搜索")
                .popover(isPresented: $showHelp, arrowEdge: .bottom) { helpPopover }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Reveal the search box, prefilled with `/h` and focused so the user can
    /// press Return for help or type over it to filter.
    private func openSearch() {
        searchText = "/h"
        viewModel.searchFilter = ""
        showSearch = true
        searchFocused = true
    }

    private func closeSearch() {
        showSearch = false
        searchText = ""
        viewModel.searchFilter = ""
    }

    /// Live-filter the already-loaded mail. Leading `/` marks a command (e.g.
    /// `/h`), not a filter, so the full list stays visible until it's submitted.
    private func applySearchFilter(_ text: String) {
        viewModel.searchFilter = text.hasPrefix("/") ? "" : text
    }

    /// Handle Return: `/h` (or `/help`, `/?`) opens the usage help; anything else
    /// is committed as the local filter.
    private func runSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if trimmed == "/h" || trimmed == "/help" || trimmed == "/?" {
            showHelp = true
            return
        }
        viewModel.searchFilter = trimmed
    }

    // MARK: - Help

    @ViewBuilder private var helpPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("如何使用").font(.headline)
            helpRow("checkmark.square", "勾选邮件（大类 / 小类 / 单封均可批量勾选），再点左上角按钮批量操作")
            helpRow("trash", "删除：把勾选的邮件移入废纸篓（可撤销）")
            helpRow("sparkles", "AI 分析：对勾选的整簇按时间线分析")
            helpRow("envelope.open", "标记已读")
            helpRow("pencil", "编辑自定义分类标签（按主题关键词归类）")
            helpRow("arrow.clockwise", "刷新：按默认规则重新拉取邮件")
            helpRow("hand.point.up.left", "双击某一行查看邮件内容")
            helpRow("doc.on.doc", "右键某一行可复制主题 / 发件人，便于搜索")
            helpRow("magnifyingglass", "点右上角放大镜展开搜索框，在当前已加载的邮件里按主题 / 发件人过滤；输入 /h 回车随时打开本帮助")

            Divider().padding(.vertical, 2)

            Text("默认过滤规则").font(.subheadline).bold()
            helpRow("line.3.horizontal.decrease.circle", "is:unread in:inbox newer_than:30d —— 只拉取最近 30 天、收件箱里的未读邮件")

            Text("默认设置").font(.subheadline).bold()
            helpRow("tray.full", "每次最多拉取 200 封")
            helpRow("rectangle.3.group", "按 Gmail 分类 + 主题聚类自动分组（大类 / 小类）")
            helpRow("square", "默认全部未勾选，由你自行选择要处理的邮件")
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder private func helpRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 18)
                .foregroundStyle(theme.textSecondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Tag editor

    @ViewBuilder private var tagEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("自定义分类标签").font(.headline)
            Text("每行一条「分类名: 主题关键词」。主题命中关键词的邮件会单独归为该分类（优先于 Gmail 分类）。")
                .font(.caption).foregroundStyle(theme.textSecondary)
            TextEditor(text: $tagDraft)
                .font(.system(size: 13, design: .monospaced))
                .frame(minWidth: 380, minHeight: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.divider))
            HStack {
                Text("例：GitHub: zbb88888").font(.caption).foregroundStyle(theme.textSecondary)
                Spacer()
                Button("取消") { showTagEditor = false }
                Button("保存") {
                    AppSettings.shared.mailTagRules = tagDraft
                    viewModel.regroup()
                    showTagEditor = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Load the stored rules every time the editor opens (reliable even when
        // the sheet is presented in the same action that would set @State).
        .onAppear { tagDraft = AppSettings.shared.mailTagRules }
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch viewModel.phase {
        case .needsConnection:
            centered {
                VStack(spacing: 12) {
                    if !viewModel.isConfigured {
                        Text("请先在设置（⌘,）中填写 Google OAuth Client ID。")
                            .foregroundStyle(theme.textSecondary)
                    }
                    Button("连接 Gmail") { Task { await viewModel.connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!viewModel.isConfigured)
                }
            }
        case .connecting:
            centered { progress("正在等待浏览器授权…") }
        case .loading:
            centered { progress("正在拉取并分组邮件…") }
        case .failed(let message):
            centered {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(theme.warning)
                    Text(message).multilineTextAlignment(.center).foregroundStyle(theme.textSecondary)
                    Button("重试") { Task { await viewModel.load() } }
                }
                .padding()
            }
        case .review:
            reviewList
        }
    }

    /// Empty-state copy: distinguishes "not loaded yet", "no mail at all", and
    /// "filter matched nothing".
    private var emptyReviewText: String {
        if !viewModel.hasLoaded { return "点击右上角「刷新」加载未读邮件" }
        let filter = viewModel.searchFilter.trimmingCharacters(in: .whitespaces)
        if !filter.isEmpty { return "没有匹配「\(filter)」的邮件。" }
        return "没有匹配的邮件。"
    }

    @ViewBuilder private var reviewList: some View {
        if viewModel.groupedClusters.isEmpty {
            centered {
                Text(emptyReviewText)
                    .foregroundStyle(theme.textSecondary)
            }
        } else {
            if let undo = viewModel.undoAction {
                undoBanner(undo)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.groupedClusters, id: \.primary) { group in
                        primarySection(group.primary, subgroups: group.subgroups)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Primary section (大类) → secondary subgroups (小类)

    @ViewBuilder private func primarySection(
        _ primary: String,
        subgroups: [(secondary: String?, clusters: [MailCluster])]
    ) -> some View {
        let color = primaryColor(primary)
        let allClusters = subgroups.flatMap { $0.clusters }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { viewModel.isGroupFullySelected(allClusters) },
                    set: { _ in viewModel.toggleGroup(allClusters) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)

                Circle().fill(color).frame(width: 9, height: 9)
                Text(primary).font(.system(size: 14, weight: .semibold))
                Text("\(viewModel.groupCount(allClusters))")
                    .font(.caption).foregroundStyle(theme.textSecondary)
                Spacer()
            }

            ForEach(Array(subgroups.enumerated()), id: \.offset) { _, sub in
                subgroupSection(sub.secondary, clusters: sub.clusters, color: color)
            }
        }
    }

    @ViewBuilder private func subgroupSection(
        _ secondary: String?,
        clusters: [MailCluster],
        color: Color
    ) -> some View {
        // Indent ladder: primary header 0 → secondary header 16 → rows one level
        // deeper than their parent header (32 under a secondary, 16 directly
        // under the primary), so every row sits deeper than its heading.
        let rowIndent: CGFloat = secondary == nil ? 16 : 32
        VStack(alignment: .leading, spacing: 4) {
            if let secondary {
                HStack(spacing: 6) {
                    Toggle("", isOn: Binding(
                        get: { viewModel.isGroupFullySelected(clusters) },
                        set: { _ in viewModel.toggleGroup(clusters) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)

                    Text(secondary).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                    Text("\(viewModel.groupCount(clusters))")
                        .font(.caption2).foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .padding(.leading, 16)
            }

            ForEach(clusters) { cluster in
                clusterRow(cluster, color: color)
                    .padding(.leading, rowIndent)
            }
        }
    }

    // MARK: - Cluster row

    @ViewBuilder private func clusterRow(_ cluster: MailCluster, color: Color) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { viewModel.isClusterSelected(cluster) },
                    set: { _ in viewModel.toggleCluster(cluster) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)

                let subject = cluster.representativeSubject.isEmpty ? "(无主题)" : cluster.representativeSubject
                Text(subject)
                    .lineLimit(1)
                    .contextMenu {
                        Button("复制主题") { copyToPasteboard(subject) }
                    }

                Spacer()

                Text("\(cluster.count)")
                    .font(.caption).monospacedDigit()
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(theme.surface, in: Capsule())

                if cluster.count > 1 {
                    Button {
                        toggleExpanded(cluster.id)
                    } label: {
                        Image(systemName: expanded.contains(cluster.id) ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                if let message = cluster.messages.first {
                    Task { await viewModel.openDetail(message) }
                }
            }
            .help("双击查看邮件内容；右键可复制主题")

            if expanded.contains(cluster.id) {
                ForEach(cluster.messages) { message in
                    messageRow(message)
                }
                .padding(.leading, 34)
                .padding(.bottom, 6)
            }
            }
        }
        .background(theme.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private func messageRow(_ message: MailMessage) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { viewModel.isSelected(message.id) },
                set: { _ in viewModel.toggleMessage(message.id) }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)

            let subject = message.subject.isEmpty ? "(无主题)" : message.subject
            VStack(alignment: .leading, spacing: 2) {
                Text(subject).lineLimit(1).font(.callout)
                Text(message.from).lineLimit(1).font(.caption).foregroundStyle(theme.textSecondary)
            }
            .contextMenu {
                Button("复制主题") { copyToPasteboard(subject) }
                Button("复制发件人") { copyToPasteboard(message.from) }
            }
            Spacer()
            if message.hasListUnsubscribe {
                Image(systemName: "bell.slash").font(.caption).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { Task { await viewModel.openDetail(message) } }
        .help("双击查看邮件内容；右键可复制")
    }

    /// Color per primary category: PR / issue get distinct hues, 未分类 is muted,
    /// everything else uses the brand accent.
    private func primaryColor(_ primary: String) -> Color {
        switch primary {
        case "PR": return theme.success
        case "Issue": return theme.warning
        case MailGrouping.unclassified: return theme.textSecondary
        default: return theme.accent
        }
    }

    // MARK: - Undo banner

    @ViewBuilder private func undoBanner(_ undo: MailViewModel.UndoAction) -> some View {
        HStack(spacing: 10) {
            Text(undo.label).font(.callout).foregroundStyle(theme.textSecondary)
            Button("撤销") { Task { await undo.perform() } }
                .buttonStyle(.link)
            Spacer()
            Button { viewModel.dismissUndo() } label: {
                Image(systemName: "xmark").font(.caption)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭提示")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(theme.surface.opacity(0.6))
    }

    // MARK: - Helpers

    private var isBusy: Bool {
        switch viewModel.phase {
        case .connecting, .loading: return true
        default: return false
        }
    }

    private func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @ViewBuilder private func progress(_ label: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(label).foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The standalone message-detail window content (a standard large window, not an
/// in-place sheet). Renders the `MailViewModel.detail` state — loading, failed,
/// or the fetched message body.
struct MailDetailView: View {
    @Environment(MailViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    var body: some View {
        Group {
            switch viewModel.detail {
            case .loading:
                centered { progress("正在加载邮件内容…") }
            case .failed(let message):
                centered {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(theme.warning)
                        Text(message).multilineTextAlignment(.center).foregroundStyle(theme.textSecondary)
                    }
                    .padding()
                }
            case .loaded(let detail):
                content(detail)
            case .none:
                centered { EmptyView() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        // ESC closes the detail window, consistent with the chat / minimal-box
        // windows; routed via a notification so it uses the same close path.
        .onExitCommand {
            NotificationCenter.default.post(name: .houmaoCloseMailDetail, object: nil)
        }
    }

    @ViewBuilder private func content(_ detail: MailMessageDetail) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(detail.subject.isEmpty ? "(无主题)" : detail.subject)
                    .font(.title3).bold()
                    .textSelection(.enabled)
                field("发件人", detail.from)
                if !detail.to.isEmpty { field("收件人", detail.to) }
                if !detail.date.isEmpty { field("时间", detail.date) }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 10)

            Divider().overlay(theme.divider)

            ScrollView {
                Text(detail.body.isEmpty ? "(无正文)" : detail.body)
                    .font(.system(size: 14))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        }
    }

    @ViewBuilder private func field(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label).font(.caption).foregroundStyle(theme.textSecondary).frame(width: 44, alignment: .leading)
            Text(value).font(.caption).foregroundStyle(theme.textSecondary).textSelection(.enabled)
        }
    }

    @ViewBuilder private func progress(_ label: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(label).foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
