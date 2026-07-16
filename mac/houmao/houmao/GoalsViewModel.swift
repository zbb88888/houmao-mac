import Foundation
import Observation

/// Drives the goal-management panel: a list of goal documents (title only) and,
/// on open, a single Mermaid diagram detail. Editing happens through the
/// document-bound chat (`MainViewModel.startDocumentChat`), which writes the
/// updated Markdown back via `save(id:markdown:)`. See `GoalStore` for the
/// on-disk format (one `.md` per goal).
@MainActor
@Observable
final class GoalsViewModel {
    private(set) var goals: [GoalDoc] = []
    private let store: GoalStore

    init(store: GoalStore = GoalStore()) {
        self.store = store
        goals = store.load()
    }

    func reload() { goals = store.load() }

    func goal(_ id: String) -> GoalDoc? { goals.first { $0.id == id } }

    /// Create a new goal from the starter template and return it.
    @discardableResult
    func createGoal() -> GoalDoc {
        let id = GoalStore.newStem()
        let markdown = GoalStore.template()
        _ = try? store.save(id: id, markdown: markdown)
        goals = store.load()
        return GoalDoc(id: id, markdown: markdown)
    }

    func deleteGoal(_ id: String) {
        store.delete(id: id)
        goals = store.load()
    }

    /// Persist edited Markdown for a goal — called by the document-bound chat's
    /// "save to original document".
    func save(id: String, markdown: String) {
        _ = try? store.save(id: id, markdown: markdown)
        goals = store.load()
    }
}
