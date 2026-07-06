import Foundation

/// Provider-agnostic mail operations for the `/mail` cleanup workflow.
///
/// Modeled on Gmail's REST semantics but kept abstract so future providers
/// (e.g. Microsoft Graph) can conform. `GmailProvider` is the first
/// implementation. Pure Foundation / `async` so it lives in Core and works on
/// every platform.
///
/// Safety (ADR-8): `trashMessages` moves to Trash (recoverable) and is the
/// default cleanup action; `deleteMessages` is permanent and must be gated
/// behind an explicit second confirmation in the UI.
protocol MailProvider: Sendable {
    /// Coarse server-side filter (e.g. Gmail `q` syntax), capped at `maxResults`.
    /// Returns message ids only.
    func listMessages(query: String, maxResults: Int) async throws -> [String]

    /// Fetch metadata (no body) for the given ids.
    func fetchMetadata(ids: [String]) async throws -> [MailMessage]

    /// Fetch the full message (headers + decoded body) for the detail view.
    func fetchFull(id: String) async throws -> MailMessageDetail

    /// Move messages to Trash (recoverable). The cleanup action.
    func trashMessages(ids: [String]) async throws

    /// Restore messages from Trash back to the inbox (undo of `trashMessages`).
    func untrash(ids: [String]) async throws

    /// Mark messages as read (removes the `UNREAD` label).
    func markRead(ids: [String]) async throws

    /// Mark messages as unread (undo of `markRead`).
    func markUnread(ids: [String]) async throws
}

/// Errors surfaced by mail providers.
enum MailProviderError: LocalizedError {
    case notAuthenticated
    case requestFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "未登录邮箱账号"
        case .requestFailed(let msg):
            return msg
        case .invalidResponse(let debug):
            return "无效的响应: \(debug)"
        }
    }
}
