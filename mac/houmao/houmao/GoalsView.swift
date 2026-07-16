import SwiftUI

/// The goal-management panel: a list of goal titles; double-click opens the
/// detail, which shows the goal document's Mermaid diagram and an AI button that
/// opens the document-bound chat to update the goal. Humans don't edit content
/// directly — chat is the action, the document is the outcome.
struct GoalsView: View {
    @Environment(GoalsViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    @State private var detailID: String?

    var body: some View {
        Group {
            if let id = detailID, let goal = viewModel.goal(id) {
                GoalDetailView(goal: goal) { detailID = nil }
            } else {
                list
            }
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
        .onAppear { viewModel.reload() }
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack {
                Text("目标").font(.system(size: 15, weight: .semibold))
                Spacer()
                Button {
                    detailID = viewModel.createGoal().id
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("新建目标")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider().overlay(theme.divider)

            if viewModel.goals.isEmpty {
                VStack { Spacer()
                    Text("还没有目标，点 + 新建")
                        .font(.callout).foregroundStyle(theme.textSecondary)
                    Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(viewModel.goals) { goal in
                            row(goal)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func row(_ goal: GoalDoc) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "scope")
                .font(.system(size: 15))
                .foregroundStyle(theme.textSecondary)
            Text(goal.title)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
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
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("返回")
                Text(goal.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                Button(action: startEdit) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("AI 更新目标（进对话框改文档，改完保存到原文档）")
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
