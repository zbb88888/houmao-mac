import Foundation

/// Persists Do areas as human-readable Markdown task lists under
/// `<Documents>/houmao/do/<area>.md`. Pure Foundation so the parse/serialize
/// logic is unit-testable in isolation. See `docs/todo.md` for the format.
struct DoStore: Sendable {
    let directory: URL

    /// Defaults to `~/Documents/houmao/do` (same Documents root as notes/logs).
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.directory = docs.appendingPathComponent("houmao/do", isDirectory: true)
        }
    }

    private func fileURL(for kind: DoTabKind) -> URL {
        directory.appendingPathComponent(kind.fileName)
    }

    /// Load an area's topics from disk. Returns an empty array when the file is
    /// missing so the caller can seed defaults.
    func load(_ kind: DoTabKind) -> [DoTopic] {
        let url = fileURL(for: kind)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Self.parse(text)
    }

    /// Rewrite an area's file with the canonical serialization of `topics`.
    func save(_ kind: DoTabKind, topics: [DoTopic]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = Self.serialize(title: kind.title, topics: topics)
        try Data(text.utf8).write(to: fileURL(for: kind), options: .atomic)
    }

    // MARK: - Pure format helpers

    /// Parse a Markdown task-list document into topics. Lenient by design so a
    /// hand-edited file still loads: `## ` opens a topic, `- [ ]` / `- [x]`
    /// lines become items under the current topic, everything else is ignored.
    static func parse(_ text: String) -> [DoTopic] {
        var topics: [DoTopic] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let title = topicTitle(line) {
                topics.append(DoTopic(title: title))
            } else if let item = taskItem(line), !topics.isEmpty {
                topics[topics.count - 1].items.append(item)
            }
        }
        return topics
    }

    /// Canonical serialization: `# <title>`, then each topic as `## <name>`
    /// followed by its `- [ ]` / `- [x]` lines, blank-line separated.
    static func serialize(title: String, topics: [DoTopic]) -> String {
        var out = "# \(title)\n"
        for topic in topics {
            out += "\n## \(topic.title)\n"
            for item in topic.items {
                out += "- [\(item.done ? "x" : " ")] \(item.text)\n"
            }
        }
        return out
    }

    /// `## <name>` → trimmed name, else nil.
    private static func topicTitle(_ line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        return String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    /// `- [ ] text` / `- [x] text` (optional spaces) → item, else nil.
    private static func taskItem(_ line: String) -> DoItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- [") else { return nil }
        let afterDash = trimmed.dropFirst(2) // drop "- "
        guard afterDash.hasPrefix("[") else { return nil }
        let rest = afterDash.dropFirst() // after "["
        guard let close = rest.firstIndex(of: "]") else { return nil }
        let mark = rest[rest.startIndex..<close].trimmingCharacters(in: .whitespaces)
        let done: Bool
        switch mark.lowercased() {
        case "x": done = true
        case "": done = false
        default: return nil
        }
        let text = String(rest[rest.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        return DoItem(text: text, done: done)
    }
}
