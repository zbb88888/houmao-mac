import SwiftUI
import AppKit

/// The Do panel: two fixed areas (工作/生活) as a top segmented control, the
/// selected area's user-editable topics as a pill row (only one topic's detail
/// list shows at a time), and a checkable to-do list for the selected topic.
/// Topics are managed in a per-area popover. Every change persists to plain-text
/// Markdown via `DoViewModel`.
struct DoView: View {
    @Environment(DoViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    @State private var newItemText: String = ""
    @State private var showingTopicManager: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            topicBar
            Divider().overlay(theme.divider)
            detail
        }
        .background(theme.background)
        .foregroundStyle(theme.textPrimary)
    }

    // MARK: - Area tabs (工作 / 生活)

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(DoTabKind.allCases) { kind in
                let selected = viewModel.selectedTab == kind
                Button {
                    viewModel.selectedTab = kind
                } label: {
                    Text(kind.title)
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            selected ? theme.accent : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8)
                        )
                        .foregroundStyle(selected ? theme.onAccent : theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 10)
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
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .padding(6)
            }
            .buttonStyle(.plain)
            .help("管理主题")
            .popover(isPresented: $showingTopicManager, arrowEdge: .bottom) {
                TopicManagerView().environment(viewModel)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    @ViewBuilder private func topicPill(_ topic: DoTopic) -> some View {
        let selected = viewModel.currentTopicID == topic.id
        Button {
            viewModel.selectTopic(topic.id)
        } label: {
            HStack(spacing: 6) {
                Text(topic.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                if topic.openCount > 0 {
                    Text("\(topic.openCount)")
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
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail list (selected topic's items)

    @ViewBuilder private var detail: some View {
        if viewModel.currentTopic == nil {
            centered {
                VStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 28))
                        .foregroundStyle(theme.textSecondary)
                    Text("还没有主题")
                        .foregroundStyle(theme.textSecondary)
                    Button("管理主题") { showingTopicManager = true }
                }
            }
        } else {
            VStack(spacing: 0) {
                addBar
                itemList
            }
        }
    }

    private var addBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            TextField("添加待办…", text: $newItemText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .onSubmit(addItem)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(theme.surface.opacity(0.5))
        .overlay(alignment: .bottom) { Divider().overlay(theme.divider) }
    }

    @ViewBuilder private var itemList: some View {
        let items = viewModel.currentTopic?.items ?? []
        if items.isEmpty {
            centered {
                Text("暂无待办，从上方添加")
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(items) { item in
                        itemRow(item)
                    }
                }
                .padding(16)
            }
        }
    }

    @ViewBuilder private func itemRow(_ item: DoItem) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.toggle(item)
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(item.done ? theme.accent : theme.textSecondary)
            }
            .buttonStyle(.plain)

            Text(item.text)
                .font(.system(size: 14))
                .strikethrough(item.done, color: theme.textSecondary)
                .foregroundStyle(item.done ? theme.textSecondary : theme.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                viewModel.deleteItem(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help("删除")
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.divider))
        .contentShape(Rectangle())
        .contextMenu {
            Button(item.done ? "标为未完成" : "标为完成") { viewModel.toggle(item) }
            Button("删除", role: .destructive) { viewModel.deleteItem(item) }
        }
    }

    private func addItem() {
        viewModel.addItem(newItemText)
        newItemText = ""
    }

    // MARK: - Helpers

    @ViewBuilder private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack { Spacer(); content(); Spacer() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Topic manager (per-area popover)

/// Add / rename / reorder / delete the current area's topics. Deleting a topic
/// that still has items asks for confirmation to avoid losing to-dos.
private struct TopicManagerView: View {
    @Environment(DoViewModel.self) private var viewModel
    private var theme: Theme { AppTheme.current }

    @State private var newTopicTitle: String = ""
    @State private var pendingDelete: DoTopic?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("管理「\(viewModel.selectedTab.title)」主题")
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            List {
                ForEach(viewModel.currentTopics) { topic in
                    TopicEditRow(topic: topic) { requestDelete(topic) }
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
            "删除主题「\(pendingDelete?.title ?? "")」及其 \(pendingDelete?.items.count ?? 0) 条待办？",
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

    private func requestDelete(_ topic: DoTopic) {
        if topic.items.isEmpty {
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
private struct TopicEditRow: View {
    @Environment(DoViewModel.self) private var viewModel
    let topic: DoTopic
    let onDelete: () -> Void

    @State private var title: String

    init(topic: DoTopic, onDelete: @escaping () -> Void) {
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
            if topic.openCount > 0 {
                Text("\(topic.openCount)")
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
