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

    init(
        id: String,
        from: String,
        subject: String,
        snippet: String = "",
        labelIds: [String] = [],
        hasListUnsubscribe: Bool = false
    ) {
        self.id = id
        self.from = from
        self.subject = subject
        self.snippet = snippet
        self.labelIds = labelIds
        self.hasListUnsubscribe = hasListUnsubscribe
    }
}

/// Semantic category derived from provider labels — zero AI (ADR-9).
///
/// Mapped straight from Gmail's native `CATEGORY_*` labels; messages without a
/// category label fall back to `.primary`. Low-priority categories are
/// pre-checked in the review UI (the user can still change any selection).
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

    /// Whether this category is pre-selected for cleanup by default.
    var isLowPriority: Bool {
        switch self {
        case .promotions, .updates, .forums: return true
        case .social, .personal, .primary: return false
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
