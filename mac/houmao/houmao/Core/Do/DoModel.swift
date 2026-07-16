import Foundation

// MARK: - Do models
//
// The Do panel is a two-level to-do organizer: fixed "areas" (工作/生活) hold
// user-editable "topics" (清单), and each topic holds items. Active items live
// in per-area plain-text files; completing an item moves it into that area's
// monthly archive (recording start/end dates). Persisted as human-readable
// Markdown (`.txt` extension); see `docs/todo.md` and `docs/google-drive.md`.
// The `id`s here are runtime-only and are not written to disk.

/// A to-do item. Active items have `completedAt == nil`; once completed they are
/// moved to the monthly archive with both timestamps recorded.
struct DoItem: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The item's title — the single line shown in the list row.
    var text: String
    /// Optional free-form Markdown detail, shown/edited only when the row is
    /// opened for full-text editing. Empty when the item has no detail.
    var body: String
    var createdAt: Date
    var completedAt: Date?

    init(id: UUID = UUID(), text: String, body: String = "", createdAt: Date = Date(), completedAt: Date? = nil) {
        self.id = id
        self.text = text
        self.body = body
        self.createdAt = createdAt
        self.completedAt = completedAt
    }

    var done: Bool { completedAt != nil }
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

    /// Count of items (active lists only hold not-yet-done items).
    var openCount: Int { items.count }
}

/// The two fixed top-level areas. Identity is stable; the Chinese title doubles
/// as the file base name so local storage mirrors Drive 1:1.
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

    /// Active file name, e.g. `工作.txt` (content is Markdown; `.txt` extension
    /// per `docs/google-drive.md`).
    var activeFileName: String { "\(title).txt" }

    /// Monthly archive file name, e.g. `工作·2026-07·归档.txt`.
    func archiveFileName(month: String) -> String { "\(title)·\(month)·归档.txt" }

    /// Legacy file name from the first Do version (`work.md`), read once to
    /// migrate existing to-dos into the new active file.
    var legacyFileName: String { "\(rawValue).md" }

    /// Seed topics used when the backing file is missing or has no sections.
    var defaultTopics: [String] {
        switch self {
        case .work: return ["todo", "学到老"]
        case .life: return ["衣食住行", "吃喝玩乐"]
        }
    }
}

/// One area with its ordered topics (active items only).
struct DoTab: Identifiable, Sendable {
    let kind: DoTabKind
    var topics: [DoTopic]

    var id: String { kind.id }
    var title: String { kind.title }
}
