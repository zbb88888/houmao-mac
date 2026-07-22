import SwiftUI
import AppKit

/// The proactive-agent inbox (主观能动性「动态」): items the background daemon
/// surfaced without being asked — PRs requesting my review and issues assigned
/// to me. Double-clicking a row triggers its suggested `/pr` / `/issue`
/// analysis (in the chat window); the row's ✕ button just dismisses it. The
/// agent only ever suggests — nothing here acts on my behalf.
struct AgentInboxView: View {
    @Environment(AgentViewModel.self) private var viewModel
    @State private var showSettings = false
    @State private var showHelp = false
    private var theme: Theme { AppTheme.current }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
    }

    // MARK: - Header (refresh / settings / help)

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                Task { await viewModel.refresh() }
            } label: {
                if viewModel.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("刷新")

            Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }
                .help("设置")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { AgentSettingsView() }

            Button { showHelp.toggle() } label: { Image(systemName: "questionmark.circle") }
                .help("使用说明")
                .popover(isPresented: $showHelp, arrowEdge: .bottom) { AgentHelpView() }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if !viewModel.isEnabled {
            centered {
                VStack(spacing: 12) {
                    Image(systemName: "bell.slash").font(.system(size: 22)).foregroundStyle(theme.textSecondary)
                    Text("主观能动性未开启")
                        .font(.system(size: 14, weight: .semibold))
                    Text("点右上角 ⚙️ 打开「后台监听」，猴毛会主动提醒你需要处理的 PR / Issue。")
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

// MARK: - Settings popover (agent config lives here, not in ⌘,)

/// The proactive agent's own settings, surfaced from the inbox header's gear so
/// the whole feature is self-contained in one window. Binds directly to the
/// shared `AppSettings`; any change reconfigures the daemon's poll loop.
private struct AgentSettingsView: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("后台监听", isOn: $settings.agentEnabled)
                .onChange(of: settings.agentEnabled) { _, _ in reconfigure() }

            if settings.agentEnabled {
                Toggle("GitHub：请求我 review 的 PR / 指派给我的 Issue",
                       isOn: $settings.agentGitHubWatcherEnabled)
                    .font(.system(size: 12))

                HStack {
                    Text("轮询间隔").font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $settings.agentIntervalMinutes) {
                        Text("5 分钟").tag(5)
                        Text("15 分钟").tag(15)
                        Text("30 分钟").tag(30)
                        Text("60 分钟").tag(60)
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    .onChange(of: settings.agentIntervalMinutes) { _, _ in reconfigure() }
                }

                HStack {
                    Text("静默时段").font(.system(size: 12))
                    Spacer()
                    Stepper("\(settings.agentQuietStartHour):00",
                            value: $settings.agentQuietStartHour, in: 0...23)
                        .onChange(of: settings.agentQuietStartHour) { _, _ in reconfigure() }
                    Text("→").foregroundStyle(.secondary)
                    Stepper("\(settings.agentQuietEndHour):00",
                            value: $settings.agentQuietEndHour, in: 0...23)
                        .onChange(of: settings.agentQuietEndHour) { _, _ in reconfigure() }
                }

                Text("静默时段内不提醒（起=止 表示不启用）。所有动作仅为建议，需你一键确认。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func reconfigure() {
        AppDelegate.shared?.agentDaemon.applyPolicy()
    }
}

// MARK: - Help popover (usage manual)

/// The feature's usage manual, surfaced from the inbox header's question mark so
/// the docs live with the feature (not only in the ⌘K palette help).
private struct AgentHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                group("是什么", [
                    "后台常驻监听 GitHub，主动提醒你需要处理的 PR / Issue。",
                    "只感知 + 建议——所有动作需你一键确认，不会自动写 / 删。",
                ])
                group("开启", [
                    "点右上角 ⚙️ 打开「后台监听」（默认关闭）。",
                    "前置：已 gh auth login，并允许通知权限。",
                    "可调轮询间隔、静默时段、GitHub watcher 开关。",
                ])
                group("交互", [
                    "双击一行 = 触发已有的 /pr、/issue 分析（在聊天窗打开）。",
                    "右键 = 分析 / 在浏览器打开 / 复制链接 / 移除。",
                    "行内 ✕ = 移除（不再重复提醒，重启也不重现）。",
                    "⟳ 刷新 = 手动强制检查一次。",
                ])
                group("提醒", [
                    "有新项弹系统通知（多条汇总）；点通知直接打开本窗口。",
                    "也可用 rail 的「动态」图标 / /agent / ⌘K 打开。",
                ])
            }
            .padding(14)
        }
        .frame(width: 340, height: 320)
    }

    @ViewBuilder private func group(_ title: String, _ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .semibold))
            ForEach(lines, id: \.self) { line in
                Text("· \(line)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
