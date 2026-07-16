import Foundation

/// Persists Do areas as human-readable Markdown under `<Documents>/houmao/do/`.
/// Two kinds of file per area (see `docs/todo.md` / `docs/google-drive.md`):
///
/// - **Active** `工作.txt` / `生活.txt`: not-yet-done items, each carrying its
///   creation date in a trailing `<!--yyyy-MM-dd-->` comment.
/// - **Monthly archive** `工作·yyyy-MM·归档.txt`: items completed that month,
///   one line each `- 文本 · 起 yyyy-MM-dd · 止 yyyy-MM-dd`.
///
/// Pure Foundation so the parse/serialize logic is unit-testable in isolation.
struct DoStore: Sendable {
    let directory: URL

    /// Defaults to `~/Documents/houmao/do`.
    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            self.directory = docs.appendingPathComponent("houmao/do", isDirectory: true)
        }
    }

    // MARK: - Active

    /// Load an area's active topics. When the new `.txt` file is missing, a
    /// one-time migration imports not-yet-done items from the legacy `work.md` /
    /// `life.md`. Returns an empty array when nothing exists (caller seeds).
    func load(_ kind: DoTabKind) -> [DoTopic] {
        let url = directory.appendingPathComponent(kind.activeFileName)
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return Self.parseActive(text)
        }
        // Legacy migration: import open items from the first Do version.
        let legacy = directory.appendingPathComponent(kind.legacyFileName)
        if let text = try? String(contentsOf: legacy, encoding: .utf8) {
            return Self.migrateLegacy(text)
        }
        return []
    }

    /// Rewrite an area's active file.
    func save(_ kind: DoTabKind, topics: [DoTopic]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = Self.serializeActive(title: kind.title, topics: topics)
        try Data(text.utf8).write(to: directory.appendingPathComponent(kind.activeFileName), options: .atomic)
    }

    // MARK: - Archive (monthly)

    func loadArchive(_ kind: DoTabKind, month: String) -> [DoTopic] {
        let url = directory.appendingPathComponent(kind.archiveFileName(month: month))
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Self.parseArchive(text)
    }

    func saveArchive(_ kind: DoTabKind, month: String, topics: [DoTopic]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = Self.serializeArchive(title: kind.title, month: month, topics: topics)
        try Data(text.utf8).write(to: directory.appendingPathComponent(kind.archiveFileName(month: month)), options: .atomic)
    }

    /// `yyyy-MM` bucket for a completion date.
    static func monthString(_ date: Date) -> String { monthFormatter.string(from: date) }

    // MARK: - Active format (pure)

    /// Parse an active file: `## ` opens a topic; `- [ ] text <!--yyyy-MM-dd-->`
    /// adds an item (creation date from the comment, or now if absent). Lines
    /// indented under an item (two-space continuation) form that item's body.
    static func parseActive(_ text: String) -> [DoTopic] {
        var topics: [DoTopic] = []
        var bodyLines: [String] = []

        func flushBody() {
            defer { bodyLines = [] }
            guard let ti = topics.indices.last, let ii = topics[ti].items.indices.last else { return }
            while let last = bodyLines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                bodyLines.removeLast()
            }
            guard !bodyLines.isEmpty else { return }
            topics[ti].items[ii].body = bodyLines.joined(separator: "\n")
        }

        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            let indented = line.hasPrefix(" ") || line.hasPrefix("\t")
            if !indented, let title = topicTitle(line) {
                flushBody()
                topics.append(DoTopic(title: title))
            } else if !indented, let item = activeItem(line), !topics.isEmpty {
                flushBody()
                topics[topics.count - 1].items.append(item)
            } else if let ti = topics.indices.last, !topics[ti].items.isEmpty {
                // Continuation line: belongs to the current item's body. Strip one
                // level of indent (the two spaces added on serialize).
                bodyLines.append(stripBodyIndent(line))
            }
        }
        flushBody()
        return topics
    }

    static func serializeActive(title: String, topics: [DoTopic]) -> String {
        var out = "# \(title)\n"
        for topic in topics {
            out += "\n## \(topic.title)\n"
            for item in topic.items {
                out += "- [ ] \(item.text) <!--\(dayFormatter.string(from: item.createdAt))-->\n"
                if !item.body.isEmpty {
                    for bodyLine in item.body.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
                        let l = String(bodyLine)
                        out += l.isEmpty ? "\n" : "  \(l)\n"
                    }
                }
            }
        }
        return out
    }

    // MARK: - Archive format (pure)

    static func parseArchive(_ text: String) -> [DoTopic] {
        var topics: [DoTopic] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if let title = topicTitle(line) {
                topics.append(DoTopic(title: title))
            } else if let item = archiveItem(line), !topics.isEmpty {
                topics[topics.count - 1].items.append(item)
            }
        }
        return topics
    }

    static func serializeArchive(title: String, month: String, topics: [DoTopic]) -> String {
        var out = "# \(title) · 归档 \(month)\n"
        for topic in topics where !topic.items.isEmpty {
            out += "\n## \(topic.title)\n"
            for item in topic.items {
                let start = dayFormatter.string(from: item.createdAt)
                let end = dayFormatter.string(from: item.completedAt ?? item.createdAt)
                out += "- \(item.text) · 起 \(start) · 止 \(end)\n"
            }
        }
        return out
    }

    // MARK: - Line helpers

    private static func topicTitle(_ line: String) -> String? {
        guard line.hasPrefix("## ") else { return nil }
        return String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
    }

    /// Remove up to two leading spaces (the indent added to body lines on
    /// serialize), leaving the body line's own indentation intact.
    private static func stripBodyIndent(_ line: String) -> String {
        if line.hasPrefix("  ") { return String(line.dropFirst(2)) }
        if line.hasPrefix(" ") { return String(line.dropFirst(1)) }
        return line
    }

    /// `- [ ] text <!--yyyy-MM-dd-->` → item. `- [x]` (unexpected in an active
    /// file) is also accepted leniently as open.
    private static func activeItem(_ line: String) -> DoItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- [") else { return nil }
        guard let close = trimmed.firstIndex(of: "]") else { return nil }
        var rest = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)

        var created = Date()
        if let open = rest.range(of: " <!--"), rest.hasSuffix("-->") {
            let raw = String(rest[open.upperBound...].dropLast(3))
            if let d = dayFormatter.date(from: raw.trimmingCharacters(in: .whitespaces)) { created = d }
            rest = String(rest[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard !rest.isEmpty else { return nil }
        return DoItem(text: rest, createdAt: created)
    }

    /// `- 文本 · 起 yyyy-MM-dd · 止 yyyy-MM-dd` → completed item.
    private static func archiveItem(_ line: String) -> DoItem? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") else { return nil }
        let body = String(trimmed.dropFirst(2))
        guard let startRange = body.range(of: " · 起 "),
              let endRange = body.range(of: " · 止 ") else { return nil }
        let text = String(body[..<startRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let startStr = String(body[startRange.upperBound..<endRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        let endStr = String(body[endRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        let created = dayFormatter.date(from: startStr) ?? Date()
        let completed = dayFormatter.date(from: endStr) ?? created
        return DoItem(text: text, createdAt: created, completedAt: completed)
    }

    /// Import open items from a legacy `- [ ]` / `- [x]` file (drop done items;
    /// they predate timestamps). Used once when the new `.txt` is absent.
    private static func migrateLegacy(_ text: String) -> [DoTopic] {
        var topics: [DoTopic] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                topics.append(DoTopic(title: String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- [ ] "), !topics.isEmpty {
                let text = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { topics[topics.count - 1].items.append(DoItem(text: text)) }
            }
        }
        return topics
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM"
        return f
    }()
}
