import Foundation
import Observation
import os.log

private let prLog = Logger(subsystem: "com.houmao", category: "PR")

/// Drives the PR panel: fetch the current user's pull requests via `gh` —
/// currently open, plus those closed in the past three months. AI-free; this is
/// a status view of "my PRs" (see PRView), mirroring the mail panel's shell.
@MainActor
@Observable
final class PRViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var phase: Phase = .idle
    /// Currently open PRs, most recently updated first.
    var openPRs: [PullRequestItem] = []
    /// PRs closed/merged within the past `closedWindowMonths`, most recently
    /// closed first.
    var closedPRs: [PullRequestItem] = []

    /// Free-text filter set by the command palette (matches title / repo).
    var searchFilter: String = ""

    var displayedOpenPRs: [PullRequestItem] { Self.filter(openPRs, by: searchFilter) }
    var displayedClosedPRs: [PullRequestItem] { Self.filter(closedPRs, by: searchFilter) }

    private static func filter(_ items: [PullRequestItem], by query: String) -> [PullRequestItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.lowercased().contains(q) || $0.repository.nameWithOwner.lowercased().contains(q)
        }
    }

    /// How far back to include closed PRs.
    private let closedWindowMonths = 3

    private let provider = PullRequestProvider()

    /// Fetch open + recently-closed PRs concurrently and publish them.
    func load() async {
        phase = .loading
        let since = Calendar.current.date(
            byAdding: .month, value: -closedWindowMonths, to: Date()
        ) ?? Date()
        do {
            async let open = provider.fetchOpen()
            async let closed = provider.fetchClosed(since: since)
            let (openResult, closedResult) = try await (open, closed)
            openPRs = openResult.sorted { $0.updatedAt > $1.updatedAt }
            closedPRs = closedResult.sorted {
                ($0.closedAt ?? $0.updatedAt) > ($1.closedAt ?? $1.updatedAt)
            }
            phase = .loaded
        } catch {
            prLog.error("load PR failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }
}
