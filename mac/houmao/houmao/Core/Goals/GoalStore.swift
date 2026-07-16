import Foundation

/// Persists goals under `<Documents>/houmao/goals/<工作|生活>/<主题>/<stem>.md` —
/// one Markdown file per goal, grouped by area and user-editable topic (each
/// topic is a folder). Each area also keeps a `_topics.txt` manifest recording
/// topic order (and preserving empty topics). Mirrors the Do two-level layout.
/// The manifest parse/serialize helpers are pure so they can be unit-tested.
struct GoalStore: Sendable {
    let root: URL

    /// Defaults to `~/Documents/houmao/goals`.
    init(directory: URL? = nil) {
        if let directory {
            self.root = directory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.root = docs.appendingPathComponent("houmao/goals", isDirectory: true)
        }
    }

    private let manifestName = "_topics.txt"

    private func areaDir(_ kind: DoTabKind) -> URL {
        root.appendingPathComponent(kind.title, isDirectory: true)
    }
    private func topicDir(_ kind: DoTabKind, _ topic: String) -> URL {
        areaDir(kind).appendingPathComponent(topic, isDirectory: true)
    }
    private func manifestURL(_ kind: DoTabKind) -> URL {
        areaDir(kind).appendingPathComponent(manifestName)
    }

    // MARK: - Load

    /// Load an area's topics, ordered by the manifest then any extra folders,
    /// each with its goals (sorted by title). Empty when the area has nothing.
    func loadTopics(_ kind: DoTabKind) -> [GoalTopic] {
        let manifestTitles: [String] = (try? String(contentsOf: manifestURL(kind), encoding: .utf8))
            .map(Self.parseManifest) ?? []

        let fm = FileManager.default
        let folderNames: [String] = ((try? fm.contentsOfDirectory(
            at: areaDir(kind), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .map { $0.lastPathComponent }

        var ordered = manifestTitles
        for name in folderNames.sorted() where !ordered.contains(name) {
            ordered.append(name)
        }
        return ordered.map { title in
            GoalTopic(title: title, goals: loadGoals(kind, topic: title))
        }
    }

    private func loadGoals(_ kind: DoTabKind, topic: String) -> [GoalDoc] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: topicDir(kind, topic), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        var docs: [GoalDoc] = []
        for url in urls where url.pathExtension.lowercased() == "md" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            docs.append(GoalDoc(id: url.deletingPathExtension().lastPathComponent, markdown: text))
        }
        return docs.sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    // MARK: - Save / delete

    /// Rewrite an area's topic-order manifest.
    func saveManifest(_ kind: DoTabKind, topicTitles: [String]) {
        try? FileManager.default.createDirectory(at: areaDir(kind), withIntermediateDirectories: true)
        let text = Self.serializeManifest(title: kind.title, topicTitles: topicTitles)
        try? Data(text.utf8).write(to: manifestURL(kind), options: .atomic)
    }

    @discardableResult
    func saveGoal(_ kind: DoTabKind, topic: String, id: String, markdown: String) -> URL? {
        let dir = topicDir(kind, topic)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(id).md")
            try Data(markdown.utf8).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    func deleteGoal(_ kind: DoTabKind, topic: String, id: String) {
        try? FileManager.default.removeItem(at: topicDir(kind, topic).appendingPathComponent("\(id).md"))
    }

    /// Rename a topic folder (its goal files move with it). No-op when the source
    /// folder doesn't exist yet (an empty topic lives only in the manifest).
    func renameTopicFolder(_ kind: DoTabKind, from: String, to: String) {
        guard from != to else { return }
        let src = topicDir(kind, from)
        let dst = topicDir(kind, to)
        if FileManager.default.fileExists(atPath: src.path) {
            try? FileManager.default.moveItem(at: src, to: dst)
        }
    }

    func deleteTopicFolder(_ kind: DoTabKind, topic: String) {
        try? FileManager.default.removeItem(at: topicDir(kind, topic))
    }

    // MARK: - Legacy migration

    /// Move any flat `*.md` goals left at the `goals/` root (the pre-topics
    /// layout) into `<area>/<topic>/`. Returns the moved count.
    @discardableResult
    func migrateFlatGoals(into kind: DoTabKind, topic: String) -> Int {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return 0 }
        let flat = urls.filter { $0.pathExtension.lowercased() == "md" }
        guard !flat.isEmpty else { return 0 }
        let dir = topicDir(kind, topic)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var moved = 0
        for url in flat {
            let dst = dir.appendingPathComponent(url.lastPathComponent)
            do { try fm.moveItem(at: url, to: dst); moved += 1 } catch {}
        }
        if moved > 0 {
            saveManifest(kind, topicTitles: loadTopics(kind).map(\.title))
        }
        return moved
    }

    // MARK: - Stems / template

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

    // MARK: - Manifest format (pure)

    /// Parse a topic manifest: `- <title>` lines in order (deduplicated).
    static func parseManifest(_ text: String) -> [String] {
        var titles: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") else { continue }
            let title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty, !titles.contains(title) { titles.append(title) }
        }
        return titles
    }

    static func serializeManifest(title: String, topicTitles: [String]) -> String {
        var out = "# \(title)\n"
        for t in topicTitles { out += "- \(t)\n" }
        return out
    }
}
