import Foundation

/// A group of near-duplicate messages sharing one category (ADR-9).
///
/// Produced by `MailGrouping`: classification comes from Gmail labels, the
/// clustering of subjects comes from the AI-free `TextClustering` module.
struct MailCluster: Identifiable, Sendable {
    let id: UUID
    let category: MailCategory
    let messages: [MailMessage]

    init(id: UUID = UUID(), category: MailCategory, messages: [MailMessage]) {
        self.id = id
        self.category = category
        self.messages = messages
    }

    /// Representative subject shown as the cluster's one-line summary.
    var representativeSubject: String {
        messages.first?.subject ?? ""
    }

    var count: Int { messages.count }

    /// Whether this cluster is pre-selected for cleanup (low-priority category).
    var isPreselected: Bool { category.isLowPriority }
}

/// Assembles messages into category → cluster groups without any AI.
///
/// 1. Classify each message via its Gmail `labelIds` (`MailCategory.from`).
/// 2. Within each category, cluster subjects with `TextClustering`.
///
/// The two dimensions are orthogonal (ADR-9): classification is a stable label
/// read, clustering is pure char-n-gram TF-IDF cosine.
enum MailGrouping {

    /// Group messages into clusters, ordered by category priority then by
    /// descending cluster size (deterministic).
    static func group(
        _ messages: [MailMessage],
        config: TextClustering.Config = TextClustering.Config()
    ) -> [MailCluster] {
        guard !messages.isEmpty else { return [] }

        // Partition by category, preserving input order within each bucket.
        var byCategory: [MailCategory: [MailMessage]] = [:]
        for message in messages {
            let category = MailCategory.from(labelIds: message.labelIds)
            byCategory[category, default: []].append(message)
        }

        var clusters: [MailCluster] = []
        // Stable category order for a predictable UI.
        for category in MailCategory.allCases {
            guard let bucket = byCategory[category], !bucket.isEmpty else { continue }

            let subjects = bucket.map(\.subject)
            let indexGroups = TextClustering.cluster(subjects, config: config)
            for group in indexGroups {
                let members = group.map { bucket[$0] }
                clusters.append(MailCluster(category: category, messages: members))
            }
        }
        return clusters
    }
}
