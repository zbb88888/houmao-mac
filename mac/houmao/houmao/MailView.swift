import SwiftUI

/// The `/mail` cleanup page (Phase 6): review Gmail grouped by category → cluster
/// and batch-move the selection to Trash. Rendered in a standalone window,
/// mirroring the `/chat` window shell.
struct MailView: View {
    @Environment(MailViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    @State private var expanded: Set<UUID> = []
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            content
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        @Bindable var vm = viewModel
        HStack(spacing: 10) {
            Image(systemName: "envelope.badge")
                .foregroundStyle(theme.accent)
            Text("邮件清理").font(.headline)

            TextField("Gmail 过滤条件（q 语法）", text: $vm.query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)
                .onSubmit { Task { await viewModel.load() } }

            Button {
                Task { await viewModel.load() }
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .disabled(isBusy)

            if viewModel.canAnalyze {
                Button {
                    Task { await viewModel.analyzeInsights() }
                } label: {
                    if viewModel.isAnalyzing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("分析中…") }
                    } else {
                        Label("AI 分析", systemImage: "sparkles")
                    }
                }
                .disabled(isBusy || viewModel.isAnalyzing || viewModel.clusters.isEmpty)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
        case .submitting:
            centered { progress("正在提交清理…") }
        case .failed(let message):
            centered {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(theme.warning)
                    Text(message).multilineTextAlignment(.center).foregroundStyle(theme.textSecondary)
                    Button("重试") { Task { await viewModel.load() } }
                }
                .padding()
            }
        case .done(let trashed):
            centered {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle").foregroundStyle(theme.accent).font(.largeTitle)
                    Text("已移入废纸篓 \(trashed) 封（可在 Gmail 废纸篓恢复）")
                    Button("继续清理") { Task { await viewModel.load() } }
                }
            }
        case .review:
            reviewList
        }
    }

    @ViewBuilder private var reviewList: some View {
        if viewModel.clusters.isEmpty {
            centered {
                if viewModel.hasLoaded {
                    Text("没有匹配的邮件。").foregroundStyle(theme.textSecondary)
                } else {
                    Button("加载邮件") { Task { await viewModel.load() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(viewModel.clusters) { cluster in
                        clusterRow(cluster)
                    }
                }
                .padding(16)
            }
            footer
        }
    }

    // MARK: - Cluster row

    @ViewBuilder private func clusterRow(_ cluster: MailCluster) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Toggle("", isOn: Binding(
                    get: { viewModel.isClusterFullySelected(cluster) },
                    set: { _ in viewModel.toggleCluster(cluster) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)

                categoryBadge(cluster.category)

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
        .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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

    @ViewBuilder private func categoryBadge(_ category: MailCategory) -> some View {
        Text(category.displayName)
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(theme.accent.opacity(category.isLowPriority ? 0.25 : 0.12), in: Capsule())
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
        Divider().overlay(theme.divider)
        HStack {
            Text("已选 \(viewModel.selectedCount) 封")
                .foregroundStyle(theme.textSecondary)
            Spacer()
            if viewModel.insights.values.contains(where: { $0.suggestDelete }) {
                Button {
                    viewModel.applyAISuggestions()
                } label: {
                    Label("应用 AI 建议", systemImage: "sparkles")
                }
            }
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Text("永久删除…")
            }
            .disabled(viewModel.selectedCount == 0)

            Button {
                Task { await viewModel.submitCleanup() }
            } label: {
                Text("移入废纸篓（\(viewModel.selectedCount)）")
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.selectedCount == 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .confirmationDialog(
            "永久删除 \(viewModel.selectedCount) 封邮件？此操作不可恢复。",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                Task { await viewModel.permanentlyDelete() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Helpers

    private var isBusy: Bool {
        switch viewModel.phase {
        case .connecting, .loading, .submitting: return true
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
