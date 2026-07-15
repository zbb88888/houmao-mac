import Foundation
import Observation
import os.log

private let doVMLog = Logger(subsystem: "com.houmao", category: "DoViewModel")

/// Drives the Do panel: two fixed areas (工作/生活), each holding user-editable
/// topics of checkable items. Persists every change to plain-text Markdown via
/// `DoStore`. Selection state (current area + current topic per area) is
/// runtime-only. See `docs/todo.md` for the storage format.
@MainActor
@Observable
final class DoViewModel {
    private(set) var tabs: [DoTab]
    var selectedTab: DoTabKind = .work
    /// Currently shown topic per area (master-detail: one detail list at a time).
    private var selectedTopicID: [DoTabKind: UUID] = [:]

    private let store: DoStore

    init(store: DoStore = DoStore()) {
        self.store = store
        tabs = DoTabKind.allCases.map { kind in
            var topics = store.load(kind)
            if topics.isEmpty {
                topics = kind.defaultTopics.map { DoTopic(title: $0) }
            }
            return DoTab(kind: kind, topics: topics)
        }
        for tab in tabs {
            selectedTopicID[tab.kind] = tab.topics.first?.id
        }
    }

    // MARK: - Derived accessors

    private var currentTabIndex: Int {
        tabs.firstIndex { $0.kind == selectedTab } ?? 0
    }

    var currentTopics: [DoTopic] { tabs[currentTabIndex].topics }

    var currentTopicID: UUID? { selectedTopicID[selectedTab] }

    var currentTopic: DoTopic? {
        currentTopics.first { $0.id == currentTopicID }
    }

    func selectTopic(_ id: UUID) {
        selectedTopicID[selectedTab] = id
    }

    // MARK: - Item operations (on the current topic)

    func addItem(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let topicIndex = currentTopicIndex() else { return }
        tabs[currentTabIndex].topics[topicIndex].items.append(DoItem(text: trimmed))
        persist(selectedTab)
    }

    func toggle(_ item: DoItem) {
        guard let topicIndex = currentTopicIndex(),
              let itemIndex = itemIndex(item, in: topicIndex) else { return }
        tabs[currentTabIndex].topics[topicIndex].items[itemIndex].done.toggle()
        persist(selectedTab)
    }

    func deleteItem(_ item: DoItem) {
        guard let topicIndex = currentTopicIndex(),
              let itemIndex = itemIndex(item, in: topicIndex) else { return }
        tabs[currentTabIndex].topics[topicIndex].items.remove(at: itemIndex)
        persist(selectedTab)
    }

    // MARK: - Topic operations (on the current area)

    func addTopic(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let topic = DoTopic(title: trimmed)
        tabs[currentTabIndex].topics.append(topic)
        if currentTopicID == nil { selectedTopicID[selectedTab] = topic.id }
        persist(selectedTab)
    }

    func renameTopic(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = tabs[currentTabIndex].topics.firstIndex(where: { $0.id == id }) else { return }
        tabs[currentTabIndex].topics[index].title = trimmed
        persist(selectedTab)
    }

    func deleteTopic(_ id: UUID) {
        guard let index = tabs[currentTabIndex].topics.firstIndex(where: { $0.id == id }) else { return }
        tabs[currentTabIndex].topics.remove(at: index)
        if currentTopicID == id {
            selectedTopicID[selectedTab] = tabs[currentTabIndex].topics.first?.id
        }
        persist(selectedTab)
    }

    func moveTopics(fromOffsets: IndexSet, toOffset: Int) {
        tabs[currentTabIndex].topics.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist(selectedTab)
    }

    // MARK: - Helpers

    private func currentTopicIndex() -> Int? {
        guard let id = currentTopicID else { return nil }
        return tabs[currentTabIndex].topics.firstIndex { $0.id == id }
    }

    private func itemIndex(_ item: DoItem, in topicIndex: Int) -> Int? {
        tabs[currentTabIndex].topics[topicIndex].items.firstIndex { $0.id == item.id }
    }

    private func persist(_ kind: DoTabKind) {
        guard let tab = tabs.first(where: { $0.kind == kind }) else { return }
        do {
            try store.save(kind, topics: tab.topics)
        } catch {
            doVMLog.error("save do failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
