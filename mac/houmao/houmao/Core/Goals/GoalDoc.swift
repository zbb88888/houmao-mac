import Foundation

/// One goal: a Markdown document whose text describes the goal and whose trailing
/// ```mermaid block visualizes the methodology / steps to reach it. The raw
/// Markdown is the single source of truth (authored and updated by the AI via
/// the document-bound chat); `title` and `mermaid` are parsed views over it.
struct GoalDoc: Identifiable, Equatable, Sendable {
    /// Stable id = the on-disk file name stem (`<id>.md`).
    let id: String
    var markdown: String

    /// Display title: the first `# ` heading, else the first non-empty line.
    var title: String { GoalDoc.parseTitle(markdown, fallback: id) }
    /// The code inside the document's ```mermaid block, if any.
    var mermaid: String? { GoalDoc.parseMermaid(markdown) }

    // MARK: - Pure parsing

    static func parseTitle(_ md: String, fallback: String) -> String {
        for raw in md.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("# ") {
                return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
            if !line.isEmpty, !line.hasPrefix("#") {
                return line
            }
        }
        return fallback
    }

    /// Extract the code inside the first ```mermaid fenced block (variable-length
    /// fence aware), or nil when there is none.
    static func parseMermaid(_ md: String) -> String? {
        let lines = md.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var i = 0
        while i < lines.count {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            let ticks = t.prefix(while: { $0 == "`" }).count
            if ticks >= 3,
               String(t.dropFirst(ticks)).trimmingCharacters(in: .whitespaces).lowercased() == "mermaid" {
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let c = lines[i].trimmingCharacters(in: .whitespaces)
                    if !c.isEmpty, c.allSatisfy({ $0 == "`" }), c.count >= ticks { break }
                    code.append(lines[i])
                    i += 1
                }
                let joined = code.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return joined.isEmpty ? nil : joined
            }
            i += 1
        }
        return nil
    }
}
