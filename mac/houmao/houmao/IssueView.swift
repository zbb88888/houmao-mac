import SwiftUI
import AppKit

/// The Issue panel: lists the current user's open GitHub issues fetched via
/// `gh` — those assigned to me and those I authored, each grouped by repository.
/// Rendered in a standalone window, mirroring the PR panel's shell. A row
/// double-click opens the issue in the browser.
struct IssueView: View {
    @Environment(IssueViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    var body: some View {
        content
            .background(theme.background)
            .foregroundStyle(theme.textPrimary)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch viewModel.phase {
        case .idle:
            centered { progress("正在加载 Issue…") }
        case .loading:
            centered { progress("正在通过 gh 拉取 Issue…") }
        case .failed(let message):
            centered {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(theme.warning)
                    Text(message).multilineTextAlignment(.center).foregroundStyle(theme.textSecondary)
                    Button("重试") { Task { await viewModel.load() } }
                }
                .padding()
            }
        case .loaded:
            list
        }
    }

    @ViewBuilder private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                section(title: "指派给我", dot: theme.warning, issues: viewModel.assignedIssues,
                        empty: "没有指派给我的 Issue")
                section(title: "我创建的", dot: theme.success, issues: viewModel.authoredIssues,
                        empty: "没有我创建的 Issue")
            }
            .padding(16)
        }
    }

    // MARK: - Section (expanded) → repo subgroups

    @ViewBuilder private func section(
        title: String, dot: Color, issues: [IssueItem], empty: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 9, height: 9)
                Text(title).font(.system(size: 14, weight: .semibold))
                Text("\(issues.count)")
                    .font(.caption).foregroundStyle(theme.textSecondary)
                Spacer()
            }

            if issues.isEmpty {
                Text(empty)
                    .font(.callout).foregroundStyle(theme.textSecondary)
                    .padding(.leading, 16)
            } else {
                ForEach(groupByRepo(issues), id: \.repo) { group in
                    repoSubgroup(group.repo, issues: group.issues)
                }
            }
        }
    }

    // MARK: - Repo grouping

    /// Group issues by repository (`owner/repo`), preserving each repo's first
    /// appearance order (the input is already time-sorted).
    private func groupByRepo(_ issues: [IssueItem]) -> [(repo: String, issues: [IssueItem])] {
        var order: [String] = []
        var map: [String: [IssueItem]] = [:]
        for issue in issues {
            let key = issue.repository.nameWithOwner
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(issue)
        }
        return order.map { (repo: $0, issues: map[$0] ?? []) }
    }

    /// One repository's issues under a monospaced repo-name subheader. The repo
    /// name lives here, so rows don't repeat it.
    @ViewBuilder private func repoSubgroup(_ repo: String, issues: [IssueItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(repo)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Text("\(issues.count)")
                    .font(.caption2).foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .padding(.leading, 16)

            ForEach(issues) { issue in
                issueRow(issue).padding(.leading, 24)
            }
        }
    }

    // MARK: - Issue row

    @ViewBuilder private func issueRow(_ issue: IssueItem) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(theme.success).frame(width: 3)
            HStack(spacing: 8) {
                Text(issue.title.isEmpty ? "(无标题)" : issue.title)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.dateFormatter.string(from: issue.updatedAt))
                    .font(.caption2).foregroundStyle(theme.textSecondary)
                    .fixedSize()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
        }
        .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.divider))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(issue) }
        .contextMenu {
            Button("在浏览器打开") { open(issue) }
            Button("复制链接") { copyToPasteboard(issue.url) }
        }
        .help("双击在浏览器打开")
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd"
        return f
    }()

    private func open(_ issue: IssueItem) {
        if let url = URL(string: issue.url) { NSWorkspace.shared.open(url) }
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @ViewBuilder private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private func progress(_ text: String) -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(text).foregroundStyle(theme.textSecondary)
        }
    }
}
