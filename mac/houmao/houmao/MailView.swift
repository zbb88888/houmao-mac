import SwiftUI

/// The `/mail` cleanup page (Phase 6): review Gmail grouped by category → cluster
/// and batch-move the selection to Trash. Rendered in a standalone window,
/// mirroring the `/chat` window shell.
struct MailView: View {
    @Environment(MailViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    @State private var expanded: Set<UUID> = []
    @State private var showTagEditor = false
    @State private var tagDraft = ""

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
        @Bindable var vm = viewModel
        HStack(spacing: 10) {
            TextField("Gmail 过滤条件（q 语法）", text: $vm.query)
                .textFieldStyle(.plain)
                .foregroundStyle(theme.textPrimary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.divider))
                .frame(maxWidth: 320)
                .onSubmit { Task { await viewModel.load() } }

            Button {
                Task { await viewModel.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")
            .accessibilityLabel("刷新")
            .disabled(isBusy)

            Button {
                tagDraft = AppSettings.shared.mailTagRules
                showTagEditor = true
            } label: {
                Image(systemName: "pencil")
            }
            .help("编辑自定义分类标签")
            .accessibilityLabel("编辑自定义分类标签")

            if viewModel.canAnalyze {
                Button {
                    Task { await viewModel.analyzeInsights() }
                } label: {
                    if viewModel.isAnalyzing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "sparkles")
                    }
                }
                .help("AI 分析")
                .accessibilityLabel("AI 分析")
                .disabled(isBusy || viewModel.isAnalyzing || viewModel.clusters.isEmpty)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    @ViewBuilder private var reviewList: some View {
        if viewModel.clusters.isEmpty {
            centered {
                Text(viewModel.hasLoaded ? "没有匹配的邮件。" : "点击右上角「刷新」加载未读邮件")
                    .foregroundStyle(theme.textSecondary)
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(viewModel.groupedClusters, id: \.key) { group in
                        groupSection(group.key, clusters: group.clusters)
                    }
                }
                .padding(16)
            }
            footer
        }
    }

    // MARK: - Group section (non-collapsing folder)

    @ViewBuilder private func groupSection(_ key: MailGroupKey, clusters: [MailCluster]) -> some View {
        let color = groupColor(key)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(
                    get: { viewModel.isGroupFullySelected(clusters) },
                    set: { _ in viewModel.toggleGroup(clusters) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)

                Circle().fill(color).frame(width: 9, height: 9)
                Text(key.displayName).font(.system(size: 13, weight: .semibold))
                Text("\(viewModel.groupCount(clusters))")
                    .font(.caption).foregroundStyle(theme.textSecondary)
                Spacer()
            }

            ForEach(clusters) { cluster in
                clusterRow(cluster, color: color)
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
                    get: { viewModel.isClusterFullySelected(cluster) },
                    set: { _ in viewModel.toggleCluster(cluster) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)

                Text(cluster.representativeSubject.isEmpty ? "(无主题)" : cluster.representativeSubject)
                    .lineLimit(1)

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

            if let insight = viewModel.insights[cluster.id] {
                HStack(spacing: 8) {
                    importanceBadge(insight.importance)
                    Text(insight.summary)
                        .font(.caption)
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                    if insight.suggestDelete {
                        Text("建议清理")
                            .font(.caption2)
                            .foregroundStyle(theme.warning)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }

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

            VStack(alignment: .leading, spacing: 2) {
                Text(message.subject.isEmpty ? "(无主题)" : message.subject).lineLimit(1).font(.callout)
                Text(message.from).lineLimit(1).font(.caption).foregroundStyle(theme.textSecondary)
            }
            Spacer()
            if message.hasListUnsubscribe {
                Image(systemName: "bell.slash").font(.caption).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(.vertical, 3)
    }

    /// Color per display group: custom tags use the brand accent (they stand out
    /// from the pastel Gmail categories); Gmail categories get distinct hues.
    private func groupColor(_ key: MailGroupKey) -> Color {
        switch key {
        case .custom: return theme.accent
        case .gmail(let category): return categoryColor(category)
        }
    }

    /// Distinct, muted accent per category to make groups scannable at a glance.
    private func categoryColor(_ category: MailCategory) -> Color {
        switch category {
        case .promotions: return .orange
        case .social: return .blue
        case .updates: return .purple
        case .forums: return .brown
        case .personal: return .pink
        case .primary: return theme.accent
        }
    }

    @ViewBuilder private func importanceBadge(_ importance: MailClusterInsight.Importance) -> some View {
        let color: Color = switch importance {
        case .high: theme.warning
        case .medium: theme.accent
        case .low: theme.textSecondary
        }
        Text("重要度 \(importance.displayName)")
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(Capsule().stroke(color.opacity(0.5)))
    }

    // MARK: - Footer

    @ViewBuilder private var footer: some View {
        if let undo = viewModel.undoAction {
            undoBanner(undo)
        }
        Divider().overlay(theme.divider)
        HStack(spacing: 12) {
            Text("\(viewModel.selectedCount)")
                .foregroundStyle(theme.textSecondary)
            if viewModel.isMutating {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if viewModel.insights.values.contains(where: { $0.suggestDelete }) {
                Button {
                    viewModel.applyAISuggestions()
                } label: {
                    Image(systemName: "wand.and.stars")
                }
                .help("应用 AI 建议")
                .accessibilityLabel("应用 AI 建议")
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
                Task { await viewModel.submitCleanup() }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("删除（移入废纸篓）")
            .accessibilityLabel("删除，移入废纸篓")
            .disabled(viewModel.selectedCount == 0 || viewModel.isMutating)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder private func undoBanner(_ undo: MailViewModel.UndoAction) -> some View {
        Divider().overlay(theme.divider)
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
