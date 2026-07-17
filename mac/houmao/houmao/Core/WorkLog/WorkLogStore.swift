import Foundation

/// Persists per-item work summaries as human-readable Markdown under
/// `<Documents>/houmao/worklog/`, organized by repository then month:
///
/// ```
/// worklog/
///   owner__name/
///     2026-07/
///       pr-1234.md
///       issue-567.md
///   _aggregate/
///     2026-Q1.md              # per-period OKR roll-up
/// ```
///
/// Each item file carries a small `---` header (so it round-trips back to a
/// `WorkItem`) followed by the free-text summary. The store is intentionally a
/// plain value type over the file system; `parse`/`serialize` are pure and
/// unit-tested.
struct WorkLogStore {
    let root: URL

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let docs = try? FileManager.default.url(
                for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )
            self.root = (docs ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("houmao/worklog", isDirectory: true)
        }
    }

    // MARK: - Paths

    private func repoFolder(_ slug: String) -> String {
        slug.replacingOccurrences(of: "/", with: "__")
    }

    func itemURL(kind: WorkKind, number: Int, repoSlug: String, monthKey: String) -> URL {
        root
            .appendingPathComponent(repoFolder(repoSlug), isDirectory: true)
            .appendingPathComponent(monthKey, isDirectory: true)
            .appendingPathComponent("\(kind.rawValue)-\(number).md")
    }

    private var aggregateFolder: URL {
        root.appendingPathComponent("_aggregate", isDirectory: true)
    }

    // MARK: - Item cache

    /// Write one item's summary file (creating parent folders).
    func save(_ item: WorkItem) throws {
        let url = itemURL(kind: item.kind, number: item.number, repoSlug: item.repoSlug, monthKey: item.monthKey)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(Self.serialize(item).utf8).write(to: url, options: .atomic)
    }

    /// Load every cached item across all repos/months. Malformed files are
    /// skipped (best-effort).
    func loadAll() -> [WorkItem] {
        let fm = FileManager.default
        guard let repoDirs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return [] }

        var items: [WorkItem] = []
        for repoDir in repoDirs {
            let name = repoDir.lastPathComponent
            guard name != "_aggregate", (try? repoDir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            guard let monthDirs = try? fm.contentsOfDirectory(at: repoDir, includingPropertiesForKeys: nil)
            else { continue }
            for monthDir in monthDirs {
                guard let files = try? fm.contentsOfDirectory(at: monthDir, includingPropertiesForKeys: nil)
                else { continue }
                for file in files where file.pathExtension == "md" {
                    if let text = try? String(contentsOf: file, encoding: .utf8),
                       let item = Self.parse(text) {
                        items.append(item)
                    }
                }
            }
        }
        return items
    }

    // MARK: - Aggregates

    func saveAggregate(name: String, markdown: String) throws {
        try FileManager.default.createDirectory(at: aggregateFolder, withIntermediateDirectories: true)
        let url = aggregateFolder.appendingPathComponent("\(name).md")
        try Data(markdown.utf8).write(to: url, options: .atomic)
    }

    // MARK: - Pure parse / serialize

    /// Serialize an item to a Markdown file: a `---` header block of `key: value`
    /// metadata followed by the free-text summary.
    static func serialize(_ item: WorkItem) -> String {
        """
        ---
        kind: \(item.kind.rawValue)
        number: \(item.number)
        repo: \(item.repoSlug)
        url: \(item.url)
        created: \(WorkItem.iso8601.string(from: item.createdAt))
        title: \(item.title.replacingOccurrences(of: "\n", with: " "))
        ---
        \(item.summary)
        """
    }

    /// Parse a serialized item file back into a `WorkItem`; nil if the header is
    /// missing required fields.
    static func parse(_ text: String) -> WorkItem? {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        var fields: [String: String] = [:]
        var bodyStart: Int?
        for i in 1..<lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "---" {
                bodyStart = i + 1
                break
            }
            let line = lines[i]
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            fields[key] = value
        }

        guard let bodyStart,
              let kindRaw = fields["kind"], let kind = WorkKind(rawValue: kindRaw),
              let number = fields["number"].flatMap({ Int($0) }),
              let repo = fields["repo"], let url = fields["url"],
              let createdRaw = fields["created"], let created = WorkItem.iso8601.date(from: createdRaw),
              let title = fields["title"]
        else { return nil }

        let summary = lines[bodyStart...].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return WorkItem(
            kind: kind, number: number, repoSlug: repo, title: title,
            url: url, createdAt: created, summary: summary
        )
    }
}
