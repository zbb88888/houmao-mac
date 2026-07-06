import Foundation

/// Lightweight, provider-agnostic email metadata (no body).
///
/// Populated from `messages.get?format=metadata` — we only pull the headers
/// needed for classification (labelIds / List-Unsubscribe) and clustering
/// (subject), never the message body. Pure Foundation so it lives in Core.
struct MailMessage: Identifiable, Equatable, Sendable {
    let id: String
    let from: String
    let subject: String
    let snippet: String
    /// Raw provider labels, e.g. Gmail `CATEGORY_PROMOTIONS`, `UNREAD`.
    let labelIds: [String]
    /// True when a `List-Unsubscribe` header is present (marketing/subscription).
    let hasListUnsubscribe: Bool
    /// Server receive time (Gmail `internalDate`), used to order a cluster's
    /// messages oldest→newest for time-line AI analysis.
    let date: Date

    init(
        id: String,
        from: String,
        subject: String,
        snippet: String = "",
        labelIds: [String] = [],
        hasListUnsubscribe: Bool = false,
        date: Date = .distantPast
    ) {
        self.id = id
        self.from = from
        self.subject = subject
        self.snippet = snippet
        self.labelIds = labelIds
        self.hasListUnsubscribe = hasListUnsubscribe
        self.date = date
    }
}

/// Full message content for the detail view, fetched on demand (double-click a
/// row). Populated from `messages.get?format=full` — includes the decoded body
/// text, which the list view intentionally omits.
struct MailMessageDetail: Identifiable, Equatable, Sendable {
    let id: String
    let from: String
    let to: String
    let subject: String
    let date: String
    /// Best-effort plain-text body (prefers a `text/plain` part; falls back to
    /// the snippet when the message has only non-text parts).
    let body: String
}

/// Semantic category derived from provider labels — zero AI (ADR-9).
///
/// Mapped straight from Gmail's native `CATEGORY_*` labels; messages without a
/// category label fall back to `.primary`. Used as the 大类 for bracket-less
/// mail so a bracket-less inbox still splits by promotions/social/updates/… .
enum MailCategory: String, CaseIterable, Sendable {
    case promotions
    case social
    case updates
    case forums
    case personal
    case primary

    /// Human-facing label for the review UI.
    var displayName: String {
        switch self {
        case .promotions: return "促销"
        case .social: return "社交"
        case .updates: return "更新通知"
        case .forums: return "论坛"
        case .personal: return "个人"
        case .primary: return "主要"
        }
    }

    /// Derive a category from Gmail `labelIds`.
    ///
    /// Gmail tags exactly one `CATEGORY_*` label per inbox message; if several
    /// were ever present we take the first match in priority order.
    static func from(labelIds: [String]) -> MailCategory {
        let labels = Set(labelIds)
        if labels.contains("CATEGORY_PROMOTIONS") { return .promotions }
        if labels.contains("CATEGORY_SOCIAL") { return .social }
        if labels.contains("CATEGORY_UPDATES") { return .updates }
        if labels.contains("CATEGORY_FORUMS") { return .forums }
        if labels.contains("CATEGORY_PERSONAL") { return .personal }
        return .primary
    }
}
