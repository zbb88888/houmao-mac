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

/// Identifies a display group: either a user custom tag or a Gmail category.
enum MailGroupKey: Hashable, Sendable {
    case custom(String)
    case gmail(MailCategory)

    var displayName: String {
        switch self {
        case .custom(let name): return name
        case .gmail(let category): return category.displayName
        }
    }
}

/// A group of near-duplicate messages sharing one group (ADR-9).
///
/// Produced by `MailGrouping`: classification comes from custom tags (subject
/// match) then Gmail labels; clustering of subjects comes from the AI-free
/// `TextClustering` module.
struct MailCluster: Identifiable, Sendable {
    let id: UUID
    let category: MailCategory
    /// Non-nil when this cluster belongs to a user custom tag (the tag name).
    let customTag: String?
    let messages: [MailMessage]

    init(id: UUID = UUID(), category: MailCategory, customTag: String? = nil, messages: [MailMessage]) {
        self.id = id
        self.category = category
        self.customTag = customTag
        self.messages = messages
    }

    /// The display group this cluster belongs to.
    var groupKey: MailGroupKey { customTag.map(MailGroupKey.custom) ?? .gmail(category) }

    /// Representative subject shown as the cluster's one-line summary.
    var representativeSubject: String {
        messages.first?.subject ?? ""
    }

    var count: Int { messages.count }

    /// Pre-selected for cleanup only for low-priority Gmail categories; custom
    /// tags are user-important, so never pre-checked.
    var isPreselected: Bool { customTag == nil && category.isLowPriority }
}

/// Assembles messages into group → cluster groups without any AI.
///
/// 1. If a message's subject matches a custom tag, it joins that tag's group
///    (custom tags win, in rule order).
/// 2. Otherwise classify via its Gmail `labelIds` (`MailCategory.from`).
/// 3. Within each group, cluster subjects with `TextClustering`.
///
/// Classification is a stable label / keyword read; clustering is pure
/// char-n-gram TF-IDF cosine (ADR-9).
enum MailGrouping {

    /// Group messages into clusters. Custom-tag groups come first (rule order),
    /// then Gmail categories (priority order); within each, clusters are ordered
    /// by descending size (deterministic).
    static func group(
        _ messages: [MailMessage],
        customTags: [MailTag] = [],
        config: TextClustering.Config = TextClustering.Config()
    ) -> [MailCluster] {
        guard !messages.isEmpty else { return [] }

        // Partition: a matching custom tag wins (rule order); else Gmail category.
        var customBuckets: [String: [MailMessage]] = [:]
        var byCategory: [MailCategory: [MailMessage]] = [:]
        for message in messages {
            if let tag = customTags.first(where: { message.subject.localizedCaseInsensitiveContains($0.keyword) }) {
                customBuckets[tag.name, default: []].append(message)
            } else {
                byCategory[MailCategory.from(labelIds: message.labelIds), default: []].append(message)
            }
        }

        var clusters: [MailCluster] = []

        // Custom-tag groups first, in rule order (unique names only).
        var seen = Set<String>()
        for tag in customTags where seen.insert(tag.name).inserted {
            guard let bucket = customBuckets[tag.name], !bucket.isEmpty else { continue }
            for members in subjectClusters(bucket, config: config) {
                clusters.append(MailCluster(
                    category: MailCategory.from(labelIds: members[0].labelIds),
                    customTag: tag.name,
                    messages: members
                ))
            }
        }

        // Then Gmail categories, in priority order.
        for category in MailCategory.allCases {
            guard let bucket = byCategory[category], !bucket.isEmpty else { continue }
            for members in subjectClusters(bucket, config: config) {
                clusters.append(MailCluster(category: category, messages: members))
            }
        }
        return clusters
    }

    /// Cluster a bucket's subjects, returning each cluster's member messages.
    private static func subjectClusters(
        _ bucket: [MailMessage],
        config: TextClustering.Config
    ) -> [[MailMessage]] {
        TextClustering.cluster(bucket.map(\.subject), config: config)
            .map { indices in indices.map { bucket[$0] } }
    }
}
