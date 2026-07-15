import Foundation

// MARK: - Do models
//
// The Do panel is a two-level to-do organizer: fixed "areas" (工作/生活) hold
// user-editable "topics" (清单), and each topic holds checkable items. Data is
// persisted as human-readable Markdown task lists — see `docs/todo.md` for the
// on-disk format. The `id`s here are runtime-only (SwiftUI identity within a
// session) and are not written to disk.

/// A single checkable to-do line: `- [ ] text` / `- [x] text`.
struct DoItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var done: Bool

    init(id: UUID = UUID(), text: String, done: Bool = false) {
        self.id = id
        self.text = text
        self.done = done
    }
}

/// A user-editable list within an area, rendered as a `## <title>` section.
struct DoTopic: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var items: [DoItem]

    init(id: UUID = UUID(), title: String, items: [DoItem] = []) {
        self.id = id
        self.title = title
        self.items = items
    }

    /// Number of not-yet-done items (shown as a badge on the topic pill).
    var openCount: Int { items.lazy.filter { !$0.done }.count }
}

/// The two fixed top-level areas. Identity is stable (backing file name);
/// the display title lives in the file's H1.
enum DoTabKind: String, CaseIterable, Identifiable, Sendable {
    case work
    case life

    var id: String { rawValue }

    var title: String {
        switch self {
        case .work: return "工作"
        case .life: return "生活"
        }
    }

    var fileName: String { "\(rawValue).md" }

    /// Seed topics used when the backing file is missing or has no sections.
    var defaultTopics: [String] {
        switch self {
        case .work: return ["todo", "学到老"]
        case .life: return ["衣食住行", "吃喝玩乐"]
        }
    }
}

/// One area with its ordered topics.
struct DoTab: Identifiable, Sendable {
    let kind: DoTabKind
    var topics: [DoTopic]

    var id: String { kind.id }
    var title: String { kind.title }
}
