import Foundation

/// One tracked unit of GitHub work — a pull request or an issue authored by the
/// current user. The atomic granularity of the work-log feature: each item gets
/// its own short (30–50 字) AI summary, cached on disk under
/// `<Documents>/houmao/worklog/<owner>__<repo>/<yyyy-MM>/<kind>-<number>.md`.
enum WorkKind: String, Sendable {
    case pr
    case issue

    /// Chinese label used in prompts and the UI.
    var label: String { self == .pr ? "PR" : "Issue" }
}

/// A GitHub repository slug as returned by `gh` (`owner/name`).
struct WorkRepo: Decodable, Sendable {
    let nameWithOwner: String
}

/// The list-level metadata decoded from `gh search prs|issues` — enough to key
/// the cache and decide whether an item still needs summarizing.
struct WorkItemRef: Decodable, Sendable {
    let number: Int
    let title: String
    let url: String
    let repository: WorkRepo
    let createdAt: Date

    var repoSlug: String { repository.nameWithOwner }
}

/// A fully-summarized work item (the cached unit).
struct WorkItem: Identifiable, Sendable, Equatable {
    var id: String { url }
    let kind: WorkKind
    let number: Int
    /// `owner/name`.
    let repoSlug: String
    let title: String
    let url: String
    let createdAt: Date
    /// The 30–50 字 AI summary of what this item did.
    let summary: String

    /// `yyyy-MM` (UTC) of `createdAt` — the month bucket for grouping/folders.
    var monthKey: String { WorkItem.monthKey(createdAt) }

    static func monthKey(_ date: Date) -> String {
        Self.monthFormatter.string(from: date)
    }

    static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM"
        return f
    }()

    static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
