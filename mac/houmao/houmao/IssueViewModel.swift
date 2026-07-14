import Foundation
import Observation
import os.log

private let issueLog = Logger(subsystem: "com.houmao", category: "Issue")

/// Drives the Issue panel: fetch the current user's open GitHub issues via
/// `gh` — those assigned to me, plus those I authored. AI-free; a status view
/// of "my issues" (see IssueView), mirroring the PR panel's shell.
@MainActor
@Observable
final class IssueViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var phase: Phase = .idle
    /// Open issues assigned to me (excluding ones I authored — those show under
    /// `authoredIssues`), most recently updated first.
    var assignedIssues: [IssueItem] = []
    /// Open issues I authored, most recently updated first.
    var authoredIssues: [IssueItem] = []

    private let provider = IssueProvider()

    /// Fetch assigned + authored issues concurrently and publish them.
    func load() async {
        phase = .loading
        do {
            async let authored = provider.fetchAuthored()
            async let assigned = provider.fetchAssigned()
            let (authoredResult, assignedResult) = try await (authored, assigned)
            let authoredSorted = authoredResult.sorted { $0.updatedAt > $1.updatedAt }
            // Drop assigned issues I also authored so the two sections don't
            // overlap — they'd already appear under 我创建的.
            let authoredURLs = Set(authoredSorted.map(\.id))
            authoredIssues = authoredSorted
            assignedIssues = assignedResult
                .filter { !authoredURLs.contains($0.id) }
                .sorted { $0.updatedAt > $1.updatedAt }
            phase = .loaded
        } catch {
            issueLog.error("load issues failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }
}
