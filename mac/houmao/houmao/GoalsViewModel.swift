import Foundation
import Observation

/// Drives the goal panel: two fixed areas (工作/生活), each holding user-editable
/// topics of goal documents (title only in the list; a Mermaid diagram in the
/// detail). Mirrors `DoViewModel`'s two-level structure. Editing a goal's content
/// happens through the document-bound chat (`MainViewModel.startDocumentChat`),
/// which writes the updated Markdown back via `save(id:markdown:)`. Selection
/// state (current area + current topic per area) is runtime-only. See
/// `GoalStore` for the on-disk layout.
@MainActor
@Observable
final class GoalsViewModel {
    private(set) var tabs: [GoalTab] = []
    var selectedTab: DoTabKind = .work
    /// Currently shown topic per area (master-detail: one detail list at a time).
    private var selectedTopicID: [DoTabKind: UUID] = [:]

    private let store: GoalStore

    /// Seed topic used for a fresh area and as the migration target for legacy
    /// flat goals.
    private static let defaultTopic = "目标"

    init(store: GoalStore = GoalStore()) {
        self.store = store
        // One-time migration of pre-topics flat goals into 工作/目标.
        store.migrateFlatGoals(into: .work, topic: Self.defaultTopic)
        buildTabs()
        for tab in tabs { selectedTopicID[tab.kind] = tab.topics.first?.id }
    }

    private func buildTabs() {
        tabs = DoTabKind.allCases.map { kind in
            var topics = store.loadTopics(kind)
            if topics.isEmpty {
                topics = [GoalTopic(title: Self.defaultTopic)]
                store.saveManifest(kind, topicTitles: topics.map(\.title))
            }
            return GoalTab(kind: kind, topics: topics)
        }
    }

    /// Re-read from disk, preserving the current topic selection by title.
    func reload() {
        let prevTitles: [DoTabKind: String] = Dictionary(uniqueKeysWithValues:
            DoTabKind.allCases.map { ($0, topicTitle(kind: $0, id: selectedTopicID[$0])) })
        buildTabs()
        for kind in DoTabKind.allCases {
            let tab = tabs.first { $0.kind == kind }
            if let title = prevTitles[kind], !title.isEmpty,
               let match = tab?.topics.first(where: { $0.title == title }) {
                selectedTopicID[kind] = match.id
            } else {
                selectedTopicID[kind] = tab?.topics.first?.id
            }
        }
    }

    // MARK: - Derived accessors

    private var currentTabIndex: Int {
        tabs.firstIndex { $0.kind == selectedTab } ?? 0
    }

    var currentTopics: [GoalTopic] { tabs[currentTabIndex].topics }

    var currentTopicID: UUID? { selectedTopicID[selectedTab] }

    var currentTopic: GoalTopic? {
        currentTopics.first { $0.id == currentTopicID }
    }

    func selectTopic(_ id: UUID) {
        selectedTopicID[selectedTab] = id
    }

    func goal(_ id: String) -> GoalDoc? {
        for tab in tabs {
            for topic in tab.topics {
                if let g = topic.goals.first(where: { $0.id == id }) { return g }
            }
        }
        return nil
    }

    // MARK: - Goal operations

    /// Create a new goal from the starter template in the current topic and
    /// return it. Returns nil when there is no current topic to add it to.
    @discardableResult
    func createGoal() -> GoalDoc? {
        guard let topicIndex = currentTopicIndex() else { return nil }
        let id = GoalStore.newStem()
        let markdown = GoalStore.template()
        let topicTitle = tabs[currentTabIndex].topics[topicIndex].title
        store.saveGoal(selectedTab, topic: topicTitle, id: id, markdown: markdown)
        let doc = GoalDoc(id: id, markdown: markdown)
        tabs[currentTabIndex].topics[topicIndex].goals.append(doc)
        return doc
    }

    func deleteGoal(_ id: String) {
        guard let loc = locate(id) else { return }
        let topicTitle = tabs[loc.tab].topics[loc.topic].title
        store.deleteGoal(tabs[loc.tab].kind, topic: topicTitle, id: id)
        tabs[loc.tab].topics[loc.topic].goals.remove(at: loc.goal)
    }

    /// Persist edited Markdown for a goal — called by the document-bound chat's
    /// "save to original document".
    func save(id: String, markdown: String) {
        guard let loc = locate(id) else { return }
        let topicTitle = tabs[loc.tab].topics[loc.topic].title
        store.saveGoal(tabs[loc.tab].kind, topic: topicTitle, id: id, markdown: markdown)
        tabs[loc.tab].topics[loc.topic].goals[loc.goal].markdown = markdown
    }

    // MARK: - Topic operations (on the current area)

    func addTopic(_ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let topic = GoalTopic(title: trimmed)
        tabs[currentTabIndex].topics.append(topic)
        if currentTopicID == nil { selectedTopicID[selectedTab] = topic.id }
        persistTopics(selectedTab)
    }

    func renameTopic(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = tabs[currentTabIndex].topics.firstIndex(where: { $0.id == id }) else { return }
        let old = tabs[currentTabIndex].topics[index].title
        guard old != trimmed else { return }
        tabs[currentTabIndex].topics[index].title = trimmed
        store.renameTopicFolder(selectedTab, from: old, to: trimmed)
        persistTopics(selectedTab)
    }

    func deleteTopic(_ id: UUID) {
        guard let index = tabs[currentTabIndex].topics.firstIndex(where: { $0.id == id }) else { return }
        let title = tabs[currentTabIndex].topics[index].title
        tabs[currentTabIndex].topics.remove(at: index)
        store.deleteTopicFolder(selectedTab, topic: title)
        if currentTopicID == id {
            selectedTopicID[selectedTab] = tabs[currentTabIndex].topics.first?.id
        }
        persistTopics(selectedTab)
    }

    func moveTopics(fromOffsets: IndexSet, toOffset: Int) {
        tabs[currentTabIndex].topics.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persistTopics(selectedTab)
    }

    // MARK: - Helpers

    private func currentTopicIndex() -> Int? {
        guard let id = currentTopicID else { return nil }
        return tabs[currentTabIndex].topics.firstIndex { $0.id == id }
    }

    private func locate(_ id: String) -> (tab: Int, topic: Int, goal: Int)? {
        for (t, tab) in tabs.enumerated() {
            for (p, topic) in tab.topics.enumerated() {
                if let g = topic.goals.firstIndex(where: { $0.id == id }) {
                    return (t, p, g)
                }
            }
        }
        return nil
    }

    private func topicTitle(kind: DoTabKind, id: UUID?) -> String {
        guard let id, let tab = tabs.first(where: { $0.kind == kind }) else { return "" }
        return tab.topics.first(where: { $0.id == id })?.title ?? ""
    }

    private func persistTopics(_ kind: DoTabKind) {
        guard let tab = tabs.first(where: { $0.kind == kind }) else { return }
        store.saveManifest(kind, topicTitles: tab.topics.map(\.title))
    }
}
