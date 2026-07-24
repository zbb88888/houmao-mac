import Foundation

/// Heuristic denoise for the proactive mail workflow (docs/proactive-agency.md
/// §8): cheaply decide, without an LLM, whether a cluster is routine noise
/// (promotions / social / subscription mail). Used only by the mail watcher to
/// avoid flooding the「动态」inbox with promo/social mail and to skip pre-warming
/// their summaries. `/mail` itself summarizes every cluster (routine included).
enum MailImportance {
    static func isRoutine(_ cluster: MailCluster) -> Bool {
        if cluster.category == .promotions || cluster.category == .social { return true }
        // A whole cluster carrying List-Unsubscribe headers is marketing /
        // subscription mail — routine by definition.
        if !cluster.messages.isEmpty, cluster.messages.allSatisfy(\.hasListUnsubscribe) {
            return true
        }
        return false
    }
}
