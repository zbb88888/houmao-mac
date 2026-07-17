import SwiftUI
import AppKit

/// The PR panel: lists the current user's pull requests fetched via `gh`.
/// Open PRs are shown expanded; PRs closed in the past three months are
/// collapsed by default. Rendered in a standalone window, mirroring the mail
/// panel's shell. A row click opens the PR in the browser.
struct PRView: View {
    @Environment(PRViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    /// Whether the "closed" section is expanded (closed PRs collapse by default).
    @State private var closedExpanded = false

    var body: some View {
        content
            .background(theme.background)
            .foregroundStyle(theme.textPrimary)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        switch viewModel.phase {
        case .idle:
            centered { progress("正在加载 PR…") }
        case .loading:
            centered { progress("正在通过 gh 拉取 PR…") }
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
                openSection
                closedSection
            }
            .padding(16)
        }
    }

    // MARK: - Repo grouping

    /// Group PRs by repository (`owner/repo`), preserving each repo's first
    /// appearance order (the input is already time-sorted).
    private func groupByRepo(_ prs: [PullRequestItem]) -> [(repo: String, prs: [PullRequestItem])] {
        var order: [String] = []
        var map: [String: [PullRequestItem]] = [:]
        for pr in prs {
            let key = pr.repository.nameWithOwner
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(pr)
        }
        return order.map { (repo: $0, prs: map[$0] ?? []) }
    }

    /// One repository's PRs under a monospaced repo-name subheader. The repo
    /// name lives here, so rows don't repeat it.
    @ViewBuilder private func repoSubgroup(_ repo: String, prs: [PullRequestItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(repo)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                Text("\(prs.count)")
                    .font(.caption2).foregroundStyle(theme.textSecondary)
                Spacer()
            }
            .padding(.leading, 16)

            ForEach(prs) { pr in
                prRow(pr).padding(.leading, 24)
            }
        }
    }

    // MARK: - Open section (expanded)

    @ViewBuilder private var openSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(theme.success).frame(width: 9, height: 9)
                Text("进行中").font(.system(size: 14, weight: .semibold))
                Text("\(viewModel.openPRs.count)")
                    .font(.caption).foregroundStyle(theme.textSecondary)
                Spacer()
            }

            if viewModel.openPRs.isEmpty {
                Text("没有进行中的 PR")
                    .font(.callout).foregroundStyle(theme.textSecondary)
                    .padding(.leading, 16)
            } else {
                ForEach(groupByRepo(viewModel.openPRs), id: \.repo) { group in
                    repoSubgroup(group.repo, prs: group.prs)
                }
            }
        }
    }

    // MARK: - Closed section (collapsed by default)

    @ViewBuilder private var closedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { closedExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: closedExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption).foregroundStyle(theme.textSecondary)
                    Circle().fill(theme.merged).frame(width: 9, height: 9)
                    Text("已关闭").font(.system(size: 14, weight: .semibold))
                    Text("\(viewModel.closedPRs.count)")
                        .font(.caption).foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if closedExpanded {
                if viewModel.closedPRs.isEmpty {
                    Text("没有已关闭的 PR")
                        .font(.callout).foregroundStyle(theme.textSecondary)
                        .padding(.leading, 16)
                } else {
                    ForEach(groupByRepo(viewModel.closedPRs), id: \.repo) { group in
                        repoSubgroup(group.repo, prs: group.prs)
                    }
                }
            }
        }
    }

    // MARK: - PR row

    @ViewBuilder private func prRow(_ pr: PullRequestItem) -> some View {
        let color = stateColor(pr)
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: 3)
            HStack(spacing: 8) {
                Text(pr.title.isEmpty ? "(无标题)" : pr.title)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(dateText(pr))
                    .font(.caption2).foregroundStyle(theme.textSecondary)
                    .fixedSize()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
        }
        .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.divider))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(pr) }
        .contextMenu {
            Button("在浏览器打开") { open(pr) }
            Button("复制链接") { copyToPasteboard(pr.url) }
        }
        .help("双击在浏览器打开")
    }

    // MARK: - Helpers

    private func stateColor(_ pr: PullRequestItem) -> Color {
        switch pr.state {
        case "open": return pr.isDraftPR ? theme.textTertiary : theme.success
        case "merged": return theme.merged
        default: return theme.danger // closed without merging
        }
    }

    /// Date shown at the row's trailing edge: month-day only (year omitted to
    /// keep it short). Closed PRs show their close date, open ones their last
    /// update.
    private func dateText(_ pr: PullRequestItem) -> String {
        let date = (!pr.isOpen ? pr.closedAt : nil) ?? pr.updatedAt
        return Self.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd"
        return f
    }()

    private func open(_ pr: PullRequestItem) {
        if let url = URL(string: pr.url) { NSWorkspace.shared.open(url) }
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
