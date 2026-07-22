import SwiftUI
import AppKit

/// The proactive-agent inbox (主观能动性「动态」): items the background daemon
/// surfaced without being asked — PRs requesting my review and issues assigned
/// to me. Double-clicking a row triggers its suggested `/pr` / `/issue`
/// analysis (in the chat window); the row's trash button just dismisses it. The
/// agent only ever suggests — nothing here acts on my behalf.
struct AgentInboxView: View {
    @Environment(AgentViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    var body: some View {
        content
            .background(theme.background)
            .foregroundStyle(theme.textPrimary)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if !viewModel.isEnabled {
            centered {
                VStack(spacing: 12) {
                    Image(systemName: "bell.slash").font(.system(size: 22)).foregroundStyle(theme.textSecondary)
                    Text("主观能动性未开启")
                        .font(.system(size: 14, weight: .semibold))
                    Text("在设置（⌘,）里开启后台监听，猴毛会主动提醒你需要处理的 PR / Issue。")
                        .font(.callout).multilineTextAlignment(.center).foregroundStyle(theme.textSecondary)
                }
                .padding()
            }
        } else if viewModel.displayedEvents.isEmpty {
            centered {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle").font(.system(size: 22)).foregroundStyle(theme.success)
                    Text("暂无新动态").font(.system(size: 14, weight: .semibold))
                    if let error = viewModel.lastError {
                        Text(error).font(.caption).multilineTextAlignment(.center).foregroundStyle(theme.warning)
                    }
                    statusLine
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        if viewModel.isRefreshing { ProgressView().controlSize(.small) } else { Text("刷新") }
                    }
                }
                .padding()
            }
        } else {
            list
        }
    }

    @ViewBuilder private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                section(title: "请求我 review", symbol: "arrow.triangle.pull", dot: theme.warning,
                        events: viewModel.reviewRequestedPRs, empty: "没有请求我 review 的 PR")
                section(title: "指派给我", symbol: "smallcircle.filled.circle", dot: theme.success,
                        events: viewModel.assignedIssues, empty: "没有指派给我的 Issue")
                statusLine.padding(.leading, 4)
            }
            .padding(16)
        }
    }

    // MARK: - Section

    @ViewBuilder private func section(
        title: String, symbol: String, dot: Color, events: [AgentEvent], empty: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(dot).frame(width: 9, height: 9)
                Text(title).font(.system(size: 14, weight: .semibold))
                Text("\(events.count)").font(.caption).foregroundStyle(theme.textSecondary)
                Spacer()
            }

            if events.isEmpty {
                Text(empty)
                    .font(.callout).foregroundStyle(theme.textSecondary)
                    .padding(.leading, 16)
            } else {
                ForEach(events) { event in
                    row(event, symbol: symbol)
                }
            }
        }
    }

    // MARK: - Row

    @ViewBuilder private func row(_ event: AgentEvent, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(theme.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.system(size: 13))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(event.subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
            }
            Text(Self.dateFormatter.string(from: event.detectedAt))
                .font(.caption2).foregroundStyle(theme.textSecondary)
                .fixedSize()
            Button {
                viewModel.dismiss(event)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(theme.danger)
            .help("移除")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.divider))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { trigger(event) }
        .contextMenu {
            Button("分析（\(event.suggestedCommand)）") { trigger(event) }
            Button("在浏览器打开") { open(event.url) }
            Button("复制链接") { copyToPasteboard(event.url) }
            Divider()
            Button("移除") { viewModel.dismiss(event) }
        }
        .help("双击触发分析")
    }

    @ViewBuilder private var statusLine: some View {
        if let polled = viewModel.lastPolledAt {
            Text("最近检查：\(Self.timeFormatter.string(from: polled))")
                .font(.caption2).foregroundStyle(theme.textSecondary)
        }
    }

    // MARK: - Actions

    /// Run the event's suggested `/pr` / `/issue` command in the shared chat
    /// dispatch. Inlined here (not in the view model) to stay on the main actor
    /// without coupling the view model to the app delegate.
    private func trigger(_ event: AgentEvent) {
        AppDelegate.shared?.mainViewModel.handleToolCommand(event.suggestedCommand)
    }

    private func open(_ urlString: String) {
        if let url = URL(string: urlString) { NSWorkspace.shared.open(url) }
    }

    private func copyToPasteboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd"
        return f
    }()

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    @ViewBuilder private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
