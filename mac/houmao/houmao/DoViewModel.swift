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
    /// Optional cloud mirror; when connected, each local save is also pushed to
    /// Google Drive (one-way, debounced). See `DriveSyncService`.
    private let driveSync: DriveSyncService?

    init(store: DoStore = DoStore(), driveSync: DriveSyncService? = nil) {
        self.store = store
        self.driveSync = driveSync
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

    /// Free-text filter set by the command palette (matches item title / body).
    var searchFilter: String = ""

    /// The current topic's items narrowed by `searchFilter`.
    var displayedItems: [DoItem] {
        let items = currentTopic?.items ?? []
        let q = searchFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter { $0.text.lowercased().contains(q) || $0.body.lowercased().contains(q) }
    }

    func selectTopic(_ id: UUID) {
        selectedTopicID[selectedTab] = id
    }

    // MARK: - Item operations (on the current topic)

    /// Create an item from full editor text (first line = title, rest = body).
    /// A blank title is a no-op (a to-do needs a title).
    func addItem(fullText: String) {
        guard let topicIndex = currentTopicIndex() else { return }
        let (title, body) = Self.splitFullText(fullText)
        guard !title.isEmpty else { return }
        tabs[currentTabIndex].topics[topicIndex].items.append(DoItem(text: title, body: body))
        persist(selectedTab)
    }

    /// Mark an active item done: stamp `completedAt`, move it out of the active
    /// list into the current month's archive, and mirror both files to Drive.
    func complete(_ item: DoItem) {
        guard let topicIndex = currentTopicIndex(),
              let itemIndex = itemIndex(item, in: topicIndex) else { return }
        var completed = tabs[currentTabIndex].topics[topicIndex].items.remove(at: itemIndex)
        completed.completedAt = Date()
        let topicTitle = tabs[currentTabIndex].topics[topicIndex].title
        archive(completed, topicTitle: topicTitle, kind: selectedTab)
        persist(selectedTab)
    }

    /// Append a completed item to its month's archive file (grouped by the topic
    /// it belonged to) and mirror that archive file to Drive.
    private func archive(_ item: DoItem, topicTitle: String, kind: DoTabKind) {
        let month = DoStore.monthString(item.completedAt ?? Date())
        var topics = store.loadArchive(kind, month: month)
        if let i = topics.firstIndex(where: { $0.title == topicTitle }) {
            topics[i].items.append(item)
        } else {
            topics.append(DoTopic(title: topicTitle, items: [item]))
        }
        do {
            try store.saveArchive(kind, month: month, topics: topics)
        } catch {
            doVMLog.error("save archive failed: \(error.localizedDescription, privacy: .public)")
        }
        let text = DoStore.serializeArchive(title: kind.title, month: month, topics: topics)
        driveSync?.scheduleMirror(name: kind.archiveFileName(month: month), content: text)
    }

    func deleteItem(_ item: DoItem) {
        guard let topicIndex = currentTopicIndex(),
              let itemIndex = itemIndex(item, in: topicIndex) else { return }
        tabs[currentTabIndex].topics[topicIndex].items.remove(at: itemIndex)
        persist(selectedTab)
    }

    /// Commit full-text edits from the inline editor. The first line becomes the
    /// title, the rest becomes the Markdown body. An empty title deletes the item.
    func updateItem(_ item: DoItem, fullText: String) {
        guard let topicIndex = currentTopicIndex(),
              let itemIndex = itemIndex(item, in: topicIndex) else { return }
        let (title, body) = Self.splitFullText(fullText)
        if title.isEmpty {
            // A to-do is identified by its first-line title; without one the item
            // is invalid (and would be dropped on reload anyway), so remove it.
            tabs[currentTabIndex].topics[topicIndex].items.remove(at: itemIndex)
            persist(selectedTab)
            return
        }
        tabs[currentTabIndex].topics[topicIndex].items[itemIndex].text = title
        tabs[currentTabIndex].topics[topicIndex].items[itemIndex].body = body
        persist(selectedTab)
    }

    /// Split editor text into a first-line title and the remaining body (trailing
    /// blank lines trimmed).
    nonisolated static func splitFullText(_ text: String) -> (title: String, body: String) {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let title = parts.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        var body = parts.count > 1 ? String(parts[1]) : ""
        while body.hasSuffix("\n") || body.hasSuffix(" ") {
            body.removeLast()
        }
        return (title, body)
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
        let text = DoStore.serializeActive(title: kind.title, topics: tab.topics)
        do {
            try store.save(kind, topics: tab.topics)
        } catch {
            doVMLog.error("save do failed: \(error.localizedDescription, privacy: .public)")
        }
        // Mirror to Drive when linked (no-op otherwise); debounced in the service.
        driveSync?.scheduleMirror(name: kind.activeFileName, content: text)
    }
}
