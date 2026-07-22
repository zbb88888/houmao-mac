import Foundation

/// Heuristic denoise for the proactive mail workflow (docs/proactive-agency.md
/// §8): cheaply decide, without an LLM, whether a cluster is routine noise
/// (promotions / social / subscription mail). The mail watcher skips LLM
/// classification for routine clusters, and `/mail` collapses them by default so
/// only real mail needs attention.
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
