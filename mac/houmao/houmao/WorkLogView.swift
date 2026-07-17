import SwiftUI
import AppKit

/// The `/worklog` panel: a two-stage GitHub work-log summarizer.
///
/// Header sets the `from` cut-off and triggers Stage 1 (fetch my PRs + issues
/// and summarize each to a 30–50 字 line). The body lists those per-item
/// summaries grouped by month (recent three months expanded, older folded). The
/// aggregate bar picks months and rolls them up into a feature-grouped report.
struct WorkLogView: View {
    @Environment(WorkLogViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    @State private var showFromPicker = false
    /// Months whose default expand/fold the user has flipped.
    @State private var toggledMonths: Set<String> = []
    @State private var showAggregate = false
    @State private var showBackground = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            content
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        .onAppear { viewModel.reload() }
        .sheet(isPresented: $showAggregate) { aggregateSheet }
    }

    // MARK: - Header

    @ViewBuilder private var header: some View {
        HStack(spacing: 10) {
            Button {
                showFromPicker = true
            } label: {
                Image(systemName: "calendar")
            }
            .help("设置起始时间（只统计此后创建的 PR / issue）")
            .popover(isPresented: $showFromPicker, arrowEdge: .bottom) { fromPicker }

            Button {
                Task { await viewModel.generate() }
            } label: {
                Image(systemName: "sparkles")
            }
            .help("生成：拉取并逐个总结我的 PR / issue（已总结的跳过）")
            .disabled(viewModel.isSummarizing)

            Button {
                viewModel.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新（重新读取本地缓存）")
            .disabled(viewModel.isSummarizing)

            Button {
                showBackground = true
            } label: {
                Image(systemName: "person.text.rectangle")
            }
            .help("编辑工作背景（OKR 总结时交给模型作为上下文）")
            .popover(isPresented: $showBackground, arrowEdge: .bottom) { backgroundEditor }

            if viewModel.isSummarizing {
                ProgressView().controlSize(.small)
                if let p = viewModel.summarizeProgress {
                    Text("总结中 \(p.done)/\(p.total)")
                        .font(.caption).foregroundStyle(theme.textSecondary)
                }
            } else {
                Text("起始 \(Self.dayLabel(viewModel.fromDate))")
                    .font(.caption).foregroundStyle(theme.textSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var fromPicker: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: 10) {
            Text("统计起始时间").font(.system(size: 13, weight: .semibold))
            DatePicker("", selection: $viewModel.fromDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack(spacing: 8) {
                quickRange("近一周", months: 0, weeks: 1)
                quickRange("近一月", months: 1)
                quickRange("近三月", months: 3)
                quickRange("近半年", months: 6)
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func quickRange(_ label: String, months: Int, weeks: Int = 0) -> some View {
        Button(label) {
            let cal = Calendar.current
            let base = Date()
            if weeks > 0 {
                viewModel.fromDate = cal.date(byAdding: .day, value: -7 * weeks, to: base) ?? base
            } else {
                viewModel.fromDate = cal.date(byAdding: .month, value: -months, to: base) ?? base
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private var backgroundEditor: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: 8) {
            Text("工作背景").font(.system(size: 13, weight: .semibold))
            Text("OKR 总结时会把这段背景交给模型，用来判断目标方向。")
                .font(.caption).foregroundStyle(theme.textSecondary)
            TextEditor(text: $viewModel.backgroundPrompt)
                .font(.system(size: 12))
                .frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.divider))
        }
        .padding(14)
        .frame(width: 360)
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if viewModel.months.isEmpty {
            centered {
                VStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 30)).foregroundStyle(theme.textSecondary)
                    if case .failed(let msg) = viewModel.phase {
                        Text(msg).multilineTextAlignment(.center).foregroundStyle(theme.danger)
                    } else {
                        Text("还没有工作记录\n设好起始时间后点上面的 ✨ 生成")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(theme.textSecondary)
                    }
                }
                .padding()
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    aggregateBar
                    ForEach(viewModel.months, id: \.self) { month in
                        monthSection(month)
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: - Aggregate bar (Stage 2)

    private var aggregateBar: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("OKR 总结").font(.system(size: 13, weight: .semibold))
                Text("选周期 → 按 OKR 归纳成果").font(.caption).foregroundStyle(theme.textSecondary)
                Spacer()
                Button {
                    Task {
                        await viewModel.runAggregate()
                        if !viewModel.aggregate.isEmpty { showAggregate = true }
                    }
                } label: {
                    if viewModel.isAggregating {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("总结选中", systemImage: "text.append")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent)
                .disabled(viewModel.selectedPeriod == nil || viewModel.isAggregating)
            }

            Picker("", selection: $viewModel.periodKind) {
                ForEach(WorkLogViewModel.PeriodKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if viewModel.periods.isEmpty {
                Text("暂无可归纳的周期").font(.caption).foregroundStyle(theme.textSecondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.periods) { period in
                            periodChip(period)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(theme.divider))
    }

    private func periodChip(_ period: WorkLogViewModel.PeriodBucket) -> some View {
        let selected = viewModel.selectedPeriodKey == period.key
        return Button {
            viewModel.selectPeriod(period.key)
        } label: {
            Text(period.label)
                .font(.system(size: 12, weight: selected ? .semibold : .regular))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(selected ? theme.accent : theme.surface, in: Capsule())
                .foregroundStyle(selected ? theme.onAccent : theme.textPrimary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Month section

    @ViewBuilder private func monthSection(_ month: String) -> some View {
        let expanded = isExpanded(month)
        let rows = viewModel.items(in: month)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if toggledMonths.contains(month) { toggledMonths.remove(month) }
                else { toggledMonths.insert(month) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11)).foregroundStyle(theme.textSecondary)
                    Text(month).font(.system(size: 14, weight: .semibold))
                    Text("\(rows.count)").font(.caption).foregroundStyle(theme.textSecondary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(rows) { item in
                    itemRow(item)
                }
            }
        }
    }

    private func isExpanded(_ month: String) -> Bool {
        // Recent months default open, older default folded; a tap flips it.
        viewModel.isRecent(month) != toggledMonths.contains(month)
    }

    // MARK: - Item row

    @ViewBuilder private func itemRow(_ item: WorkItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(item.kind.label)
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(kindColor(item.kind).opacity(0.18), in: Capsule())
                .foregroundStyle(kindColor(item.kind))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.summary.isEmpty ? item.title : item.summary)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(item.repoSlug) #\(item.number)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 7).padding(.horizontal, 10)
        .background(theme.surface.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.divider))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } }
        .contextMenu {
            Button("在浏览器打开") { if let url = URL(string: item.url) { NSWorkspace.shared.open(url) } }
            Button("复制链接") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
        }
    }

    private func kindColor(_ kind: WorkKind) -> Color {
        kind == .pr ? theme.success : theme.warning
    }

    // MARK: - Aggregate sheet

    private var aggregateSheet: some View {
        VStack(spacing: 0) {
            HStack {
                Text("OKR 工作总结").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.aggregate, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("复制 Markdown")
                Button("关闭") { showAggregate = false }
            }
            .padding(14)
            Divider().overlay(theme.divider)
            ScrollView {
                MarkdownView(text: viewModel.aggregate, baseFontSize: 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(width: 620, height: 560)
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
    }

    // MARK: - Helpers

    @ViewBuilder private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func dayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
