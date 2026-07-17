import SwiftUI

/// The goal panel — the "upgraded" Do panel: two fixed areas (工作/生活) as a top
/// segmented control, the selected area's user-editable topics as a pill row
/// (only one topic's goals show at a time), and a list of goal titles.
/// Double-click opens the detail (the goal document's Mermaid diagram + an AI
/// button that opens the document-bound chat). Humans don't edit content
/// directly — chat is the action, the document is the outcome.
struct GoalsView: View {
    @Environment(GoalsViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    @State private var detailID: String?
    @State private var showingTopicManager: Bool = false

    var body: some View {
        Group {
            if let id = detailID, let goal = viewModel.goal(id) {
                GoalDetailView(goal: goal) { detailID = nil }
            } else {
                main
            }
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        .onAppear { viewModel.reload() }
    }

    // MARK: - Main (areas + topics + goal list)

    private var main: some View {
        @Bindable var viewModel = viewModel
        return VStack(spacing: 0) {
            Picker("", selection: $viewModel.selectedTab) {
                ForEach(DoTabKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 10)

            topicBar
            Divider().overlay(theme.divider)
            detail
        }
    }

    // MARK: - Topic pills + manage button

    private var topicBar: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.currentTopics) { topic in
                        topicPill(topic)
                    }
                }
                .padding(.vertical, 2)
            }

            Button {
                showingTopicManager = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .help("管理主题")
            .popover(isPresented: $showingTopicManager, arrowEdge: .bottom) {
                GoalTopicManagerView().environment(viewModel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder private func topicPill(_ topic: GoalTopic) -> some View {
        let selected = viewModel.currentTopicID == topic.id
        Button {
            viewModel.selectTopic(topic.id)
        } label: {
            HStack(spacing: 6) {
                Text(topic.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                if topic.goalCount > 0 {
                    Text("\(topic.goalCount)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? theme.onAccent.opacity(0.85) : theme.textSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                selected ? theme.accent : theme.surface,
                in: Capsule()
            )
            .foregroundStyle(selected ? theme.onAccent : theme.textPrimary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail list (selected topic's goals)

    @ViewBuilder private var detail: some View {
        if viewModel.currentTopic == nil {
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "scope")
                        .font(.system(size: 28))
                        .foregroundStyle(theme.textSecondary)
                    Text("还没有主题")
                        .foregroundStyle(theme.textSecondary)
                    Button("管理主题") { showingTopicManager = true }
                }
            }
        } else {
            goalList
        }
    }

    @ViewBuilder private var goalList: some View {
        let goals = viewModel.displayedGoals
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(goals) { goal in
                    row(goal)
                }
                addRow
            }
            .padding(16)
        }
    }

    /// The only "add" affordance: a bottom row that creates a new goal in the
    /// current topic and opens its detail (matches the Do panel's add row).
    private var addRow: some View {
        Button {
            if let goal = viewModel.createGoal() { detailID = goal.id }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(theme.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("新建目标")
    }

    private func row(_ goal: GoalDoc) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
                .font(.system(size: 15))
                .foregroundStyle(theme.textSecondary)
            Text(goal.title)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.deleteGoal(goal.id)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(theme.danger)
            .help("删除")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.divider))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { detailID = goal.id }
        .contextMenu {
            Button("打开") { detailID = goal.id }
            Button("删除", role: .destructive) { viewModel.deleteGoal(goal.id) }
        }
    }

    // MARK: - Helpers

    @ViewBuilder private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Topic manager (per-area popover)

/// Add / rename / reorder / delete the current area's topics. Deleting a topic
/// that still has goals asks for confirmation to avoid losing them. Mirrors the
/// Do panel's topic manager.
private struct GoalTopicManagerView: View {
    @Environment(GoalsViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    @State private var newTopicTitle: String = ""
    @State private var pendingDelete: GoalTopic?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("管理「\(viewModel.selectedTab.title)」主题")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            List {
                ForEach(viewModel.currentTopics) { topic in
                    GoalTopicEditRow(topic: topic) { requestDelete(topic) }
                        .environment(viewModel)
                }
                .onMove { viewModel.moveTopics(fromOffsets: $0, toOffset: $1) }
            }
            .listStyle(.plain)
            .frame(height: 220)

            Divider().overlay(theme.divider)

            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                TextField("新主题…", text: $newTopicTitle)
                    .textFieldStyle(.plain)
                    .onSubmit(addTopic)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .background(theme.background)
        .confirmationDialog(
            "删除主题「\(pendingDelete?.title ?? "")」及其 \(pendingDelete?.goals.count ?? 0) 个目标？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                if let topic = pendingDelete { viewModel.deleteTopic(topic.id) }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        }
    }

    private func requestDelete(_ topic: GoalTopic) {
        if topic.goals.isEmpty {
            viewModel.deleteTopic(topic.id)
        } else {
            pendingDelete = topic
        }
    }

    private func addTopic() {
        viewModel.addTopic(newTopicTitle)
        newTopicTitle = ""
    }
}

/// A single editable topic row: inline rename + delete.
private struct GoalTopicEditRow: View {
    @Environment(GoalsViewModel.self) private var viewModel
    let topic: GoalTopic
    let onDelete: () -> Void

    @State private var title: String

    init(topic: GoalTopic, onDelete: @escaping () -> Void) {
        self.topic = topic
        self.onDelete = onDelete
        _title = State(initialValue: topic.title)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("主题名", text: $title)
                .textFieldStyle(.plain)
                .onSubmit { commit() }
            if topic.goalCount > 0 {
                Text("\(topic.goalCount)")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除主题")
        }
    }

    private func commit() {
        viewModel.renameTopic(topic.id, to: title)
    }
}

/// A goal's detail: just the Mermaid diagram + an AI button that opens the
/// document-bound chat.
private struct GoalDetailView: View {
    let goal: GoalDoc
    let onBack: () -> Void
    @Environment(GoalsViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                }
                .help("返回")
                Button(action: startEdit) {
                    Image(systemName: "sparkles")
                }
                .help("AI 更新目标（进对话框改文档，改完保存到原文档）")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().overlay(theme.divider)

            if let code = goal.mermaid {
                MermaidView(code: code)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack { Spacer()
                    Text("这个目标还没有图，点右上角 AI 让它拆解")
                        .font(.callout).foregroundStyle(theme.textSecondary)
                    Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @MainActor private func startEdit() {
        AppDelegate.shared?.mainViewModel.startDocumentChat(
            title: goal.title,
            markdown: goal.markdown
        ) { newMarkdown in
            viewModel.save(id: goal.id, markdown: newMarkdown)
        }
    }
}
