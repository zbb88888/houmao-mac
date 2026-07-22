import Foundation
import CryptoKit

/// Stable, cross-session identity for a mail cluster, so the proactive mail
/// watcher and the `/mail` panel can remember which clusters have been seen and
/// cache their summaries. `MailCluster.id` is a per-run `UUID` and can't
/// persist, so we derive signatures from the messages themselves.
enum MailSignature {
    /// Exact signature: SHA-256 hex of the cluster's sorted Gmail message-ids.
    /// Matches "the very same batch of emails". `hashValue` is unusable here —
    /// it's per-process randomized and not stable across launches.
    static func cluster(_ cluster: MailCluster) -> String {
        let joined = cluster.messages.map(\.id).sorted().joined(separator: "\n")
        let digest = SHA256.hash(data: Data(joined.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Family signature: normalized sender + normalized representative subject,
    /// so recurring look-alikes (newsletters / daily reports, whose message-ids
    /// differ each issue but whose template is constant) share one key.
    static func family(_ cluster: MailCluster) -> String {
        let rep = cluster.messages.first
        let sender = normalizeSender(rep?.from ?? "")
        let subject = normalizeSubject(rep?.subject ?? cluster.primary)
        return "\(sender)|\(subject)"
    }

    /// Lowercased, trimmed sender — a stable per-sender key.
    static func normalizeSender(_ from: String) -> String {
        from.lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// Lowercase, drop digits (dates / issue numbers vary per issue), collapse
    /// whitespace — so "Daily report 7/21" and "Daily report 7/22" map to the
    /// same family.
    static func normalizeSubject(_ subject: String) -> String {
        let noDigits = String(subject.lowercased().map { $0.isNumber ? " " : $0 })
        return noDigits.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
