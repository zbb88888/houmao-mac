import Foundation
import CryptoKit

/// Stable, cross-session identity for a mail cluster, so the proactive mail
/// watcher and the `/mail` panel can key cached summaries / importance to it.
/// `MailCluster.id` is a per-run `UUID` and can't persist.
enum MailSignature {
    /// SHA-256 hex of the cluster's sorted Gmail message-ids — the same batch of
    /// emails maps to the same key. `hashValue` is unusable here (it's
    /// per-process randomized and not stable across launches).
    static func cluster(_ cluster: MailCluster) -> String {
        let joined = cluster.messages.map(\.id).sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
