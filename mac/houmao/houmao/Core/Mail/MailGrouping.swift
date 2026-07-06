import Foundation

/// A user-defined tag rule: `name`（分类名，key）+ `keyword`（主题匹配词，value）。
/// Emails whose subject contains `keyword` (case-insensitive) form a separate
/// group named `name`, taking priority over Gmail's native categories.
struct MailTag: Sendable, Equatable {
    let name: String
    let keyword: String

    /// Parse one-rule-per-line text (`名称: 关键词`); accepts full-width `：` too.
    static func parse(_ text: String) -> [MailTag] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = rawLine.replacingOccurrences(of: "：", with: ":")
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let keyword = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !keyword.isEmpty else { return nil }
            return MailTag(name: name, keyword: keyword)
        }
    }
}

/// A group of near-duplicate messages sharing one two-level tag (ADR-9).
///
/// Produced by `MailGrouping`: the `primary` (大类) comes from a title keyword
/// match (PR / issue) or the `()` bracket content; the `secondary` (小类) comes
/// from the `[]` bracket content; clustering within a (primary, secondary)
/// bucket comes from the AI-free `TextClustering` module.
struct MailCluster: Identifiable, Sendable {
    let id: UUID
    /// Top-level category ("大类"): "PR" / "issue" (title match), else the
    /// normalized `()` content, else `MailGrouping.unclassified`.
    let primary: String
    /// Sub-category ("小类"): the first `[]` bracket content, or nil.
    let secondary: String?
    /// Gmail category, retained only for optional LLM insight context.
    let category: MailCategory
    let messages: [MailMessage]

    init(
        id: UUID = UUID(),
        primary: String = MailGrouping.unclassified,
        secondary: String? = nil,
        category: MailCategory,
        messages: [MailMessage]
    ) {
        self.id = id
        self.primary = primary
        self.secondary = secondary
        self.category = category
        self.messages = messages
    }

    /// Representative subject shown as the cluster's one-line summary.
    var representativeSubject: String {
        messages.first?.subject ?? ""
    }

    var count: Int { messages.count }
}

/// Assembles messages into group → cluster groups without any AI.
///
/// Assembles messages into a two-level tag tree without any AI.
///
/// 1. **Primary (大类)**: a user custom tag (subject keyword), then the built-in
///    PR / issue title match, then the normalized `()` content, else 未分类.
/// 2. **Secondary (小类)**: the first `[]` bracket content, or none.
/// 3. Within each (primary, secondary) bucket, cluster subjects with
///    `TextClustering` (char-n-gram TF-IDF cosine, ADR-9).
enum MailGrouping {

    /// Fallback primary tag for mail with no bracket / keyword classification.
    static let unclassified = "未分类"

    /// Display / priority order of the built-in primary tags.
    static let builtinTagOrder = ["PR", "issue"]

    /// Group messages into a flat list of clusters, each carrying its `primary`
    /// (大类) and `secondary` (小类) tags. Ordering: custom tags (rule order) →
    /// PR → issue → other bracket tags (first-seen) → Gmail categories; within a
    /// primary, secondaries in first-seen order (no-`[]` last); within a
    /// secondary, clusters by descending size.
    static func group(
        _ messages: [MailMessage],
        customTags: [MailTag] = [],
        config: TextClustering.Config = TextClustering.Config()
    ) -> [MailCluster] {
        guard !messages.isEmpty else { return [] }

        // Compute each message's two-level (primary, secondary) tags, then bucket
        // by primary (preserving first-seen) and emit in priority order.
        var primarySeen: [String] = []
        var byPrimary: [String: [(secondary: String?, message: MailMessage)]] = [:]
        for message in messages {
            var (primary, secondary) = tags(for: message.subject, customTags: customTags)
            // No bracket / keyword tag → fall back to the Gmail category as the
            // 大类, so bracket-less mail still splits by promotions/social/... .
            if primary == unclassified {
                primary = MailCategory.from(labelIds: message.labelIds).displayName
            }
            if byPrimary[primary] == nil { primarySeen.append(primary) }
            byPrimary[primary, default: []].append((secondary, message))
        }

        var clusters: [MailCluster] = []
        for primary in orderedPrimaries(primarySeen, customTags: customTags) {
            guard let entries = byPrimary[primary] else { continue }
            // Split by secondary (first-seen; no-secondary last), then near-neighbour.
            var secondarySeen: [String] = []
            var bySecondary: [String: [MailMessage]] = [:]
            var noSecondary: [MailMessage] = []
            for entry in entries {
                if let tag = entry.secondary {
                    if bySecondary[tag] == nil { secondarySeen.append(tag) }
                    bySecondary[tag, default: []].append(entry.message)
                } else {
                    noSecondary.append(entry.message)
                }
            }
            for tag in secondarySeen {
                appendNeighbourClusters(bySecondary[tag] ?? [], primary: primary, secondary: tag, config: config, into: &clusters)
            }
            appendNeighbourClusters(noSecondary, primary: primary, secondary: nil, config: config, into: &clusters)
        }
        return clusters
    }

    /// Priority order of primaries: custom tags (rule order) → PR → issue →
    /// other bracket tags (first-seen) → Gmail categories (fixed order).
    private static func orderedPrimaries(_ seen: [String], customTags: [MailTag]) -> [String] {
        var ordered: [String] = []
        var used = Set<String>()
        func take(_ name: String) {
            guard seen.contains(name), used.insert(name).inserted else { return }
            ordered.append(name)
        }
        for tag in customTags { take(tag.name) }
        for name in builtinTagOrder { take(name) }
        // Bracket tags before Gmail categories; categories in their fixed order.
        let categoryNames = Set(MailCategory.allCases.map(\.displayName))
        for name in seen where !categoryNames.contains(name) { take(name) }
        for category in MailCategory.allCases { take(category.displayName) }
        return ordered
    }

    private static func appendNeighbourClusters(
        _ messages: [MailMessage],
        primary: String,
        secondary: String?,
        config: TextClustering.Config,
        into clusters: inout [MailCluster]
    ) {
        for indices in TextClustering.cluster(messages.map(\.subject), config: config) {
            // Order a cluster's messages oldest→newest so AI can read the thread
            // as a time line.
            let members = indices.map { messages[$0] }.sorted { $0.date < $1.date }
            clusters.append(MailCluster(
                primary: primary,
                secondary: secondary,
                category: MailCategory.from(labelIds: members[0].labelIds),
                messages: members
            ))
        }
    }

    // MARK: - Tag extraction

    /// Bracket kinds in classification-priority order: `()` is level 1, `[]` is
    /// level 2, the rest are level 3+.
    static let bracketPairs: [(open: Character, close: Character)] = [
        ("(", ")"), ("[", "]"), ("{", "}"), ("<", ">"), ("【", "】"), ("（", "）")
    ]

    /// Two-level display tags for a subject:
    /// - **primary** (大类): a matching user custom tag; else the level-1 bracket
    ///   (`()`) content — or, when absent, the highest-priority bracket present —
    ///   normalized (PR/issue canonicalized); else a PR/issue title keyword when
    ///   there is no bracket at all; else 未分类.
    /// - **secondary** (小类): the remaining bracket levels joined with " › "
    ///   (so a 3rd+ bracket appears after the 2nd), or nil.
    static func tags(for subject: String, customTags: [MailTag] = []) -> (primary: String, secondary: String?) {
        // Custom tag is an explicit, self-contained class (no bracket sub-split).
        if let tag = customTags.first(where: { subject.localizedCaseInsensitiveContains($0.keyword) }) {
            return (tag.name, nil)
        }
        let tokens = bracketPath(subject)
        guard let first = tokens.first else {
            // No brackets: fall back to a PR/issue title keyword, else 未分类.
            if let keyword = builtinTag(subject) { return (keyword, nil) }
            return (unclassified, nil)
        }
        let primary = canonicalPrimary(first)
        let rest = tokens.dropFirst()
        let secondary = rest.isEmpty ? nil : rest.joined(separator: " › ")
        return (primary, secondary)
    }

    /// Convenience: the primary tag (大类) only. See `tags(for:customTags:)`.
    static func primaryTag(_ subject: String, customTags: [MailTag] = []) -> String {
        tags(for: subject, customTags: customTags).primary
    }

    /// Ordered, normalized contents of the brackets present, in bracket-priority
    /// order (`()` → `[]` → others). Missing brackets are skipped (they don't
    /// occupy a level). Match direction follows GitHub's notification habit:
    /// `()` is matched **right-to-left** (the `(PR #num)` / `(Issue #num)` tag
    /// sits at the far right), everything else left-to-right.
    static func bracketPath(_ subject: String) -> [String] {
        var tokens: [String] = []
        if let paren = lastParenTag(subject) { tokens.append(paren) }
        for pair in bracketPairs where pair.open != "(" {
            if let content = firstBracketContent(subject, open: pair.open, close: pair.close) {
                tokens.append(content)
            }
        }
        return tokens
    }

    /// Canonicalize a primary token so GitHub's `(PR #…)` / `(Issue #…)` render
    /// as the familiar "PR" / "issue" categories.
    static func canonicalPrimary(_ token: String) -> String {
        switch token.lowercased() {
        case "pr", "pull request", "pull requests": return "PR"
        case "issue", "issues": return "issue"
        default: return token
        }
    }

    /// Built-in primary tag from title keywords, used only when there is no
    /// bracket: `"PR"` for a pull request (the phrase "pull request" or a
    /// standalone "PR" token), `"issue"` for a standalone "issue"/"issues"
    /// token; nil otherwise. PR wins when both appear.
    static func builtinTag(_ subject: String) -> String? {
        func matches(_ pattern: String) -> Bool {
            subject.range(of: pattern, options: .regularExpression) != nil
        }
        // "pull request(s)" is case-insensitive; the "PR" abbreviation is
        // case-sensitive (uppercase) to avoid matching stray lowercase "pr".
        if matches(#"(?i)\bpull requests?\b"#) || matches(#"\bPR\b"#) { return "PR" }
        if matches(#"(?i)\bissues?\b"#) { return "issue" }
        return nil
    }

    /// Content of the first single-level `open…close` bracket, normalized: strip
    /// `#123` refs, collapse whitespace, lowercase. Nil if absent or empty.
    static func firstBracketContent(_ subject: String, open: Character, close: Character) -> String? {
        guard let openIndex = subject.firstIndex(of: open) else { return nil }
        let afterOpen = subject.index(after: openIndex)
        guard afterOpen <= subject.endIndex,
              let closeIndex = subject[afterOpen...].firstIndex(of: close) else { return nil }
        return normalizeToken(String(subject[afterOpen..<closeIndex]))
    }

    /// Content of the **last** single-level `open…close` bracket (right-to-left),
    /// normalized like `firstBracketContent`. Nil if absent or empty.
    static func lastBracketContent(_ subject: String, open: Character, close: Character) -> String? {
        guard let closeIndex = subject.lastIndex(of: close),
              let openIndex = subject[..<closeIndex].lastIndex(of: open) else { return nil }
        let afterOpen = subject.index(after: openIndex)
        return normalizeToken(String(subject[afterOpen..<closeIndex]))
    }

    /// The `()` content (level 1), matched right-to-left. See `lastBracketContent`.
    static func lastParenTag(_ subject: String) -> String? {
        lastBracketContent(subject, open: "(", close: ")")
    }

    /// The `[]` content (level 2), matched left-to-right. See `firstBracketContent`.
    static func firstBracketTag(_ subject: String) -> String? {
        firstBracketContent(subject, open: "[", close: "]")
    }

    private static func normalizeToken(_ raw: String) -> String? {
        let stripped = raw.replacingOccurrences(of: #"#\d+"#, with: "", options: .regularExpression)
        let normalized = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
