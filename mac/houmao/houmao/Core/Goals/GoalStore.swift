import Foundation

/// Persists goals as individual Markdown files under `<Documents>/houmao/goals/`,
/// one file per goal (`<stem>.md`). Pure Foundation so the file naming / listing
/// is unit-testable. Mirrors the Do / notes storage convention.
struct GoalStore: Sendable {
    let directory: URL

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.directory = docs.appendingPathComponent("houmao/goals", isDirectory: true)
        }
    }

    /// Load all goal documents, ordered by title.
    func load() -> [GoalDoc] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var docs: [GoalDoc] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            docs.append(GoalDoc(id: url.deletingPathExtension().lastPathComponent, markdown: text))
        }
        return docs.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    func save(id: String, markdown: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(id).md")
        try Data(markdown.utf8).write(to: url, options: .atomic)
        return url
    }

    func delete(id: String) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(id).md"))
    }

    /// A unique file-name stem for a new goal (timestamped so titles can repeat
    /// and the AI can freely change the displayed `# ` heading later).
    static func newStem() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "goal-\(f.string(from: Date()))"
    }

    /// Starter template for a brand-new goal.
    static func template() -> String {
        """
        # 新目标

        （用一句话描述目标；点右上角 AI 让它按方法论拆解步骤）

        ```mermaid
        flowchart TD
            A[目标] --> B[待 AI 拆解步骤]
        ```
        """
    }
}
