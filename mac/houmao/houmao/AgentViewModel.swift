import Foundation
import Observation

/// Drives the proactive-agent inbox panel: a filtered, grouped view over the
/// daemon's surfaced events, plus refresh / dismiss. Acting on an event (running
/// its `suggestedCommand`) is done by the view against `MainViewModel`, so this
/// view model stays free of shell coupling.
@MainActor
@Observable
final class AgentViewModel {
    private let daemon: AgentDaemon

    /// Free-text filter set by the command palette (matches title / repo).
    var searchFilter: String = ""
    /// True while a manual refresh is in flight (drives the spinner).
    var isRefreshing = false

    init(daemon: AgentDaemon) {
        self.daemon = daemon
    }

    var displayedEvents: [AgentEvent] {
        let q = searchFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return daemon.events }
        return daemon.events.filter {
            $0.title.lowercased().contains(q) || $0.subtitle.lowercased().contains(q)
        }
    }

    var reviewRequestedPRs: [AgentEvent] {
        displayedEvents.filter { $0.kind == .reviewRequestedPR }
    }

    var assignedIssues: [AgentEvent] {
        displayedEvents.filter { $0.kind == .assignedIssue }
    }

    var newMailClusters: [AgentEvent] {
        displayedEvents.filter { $0.kind == .newMailCluster }
    }

    var lastPolledAt: Date? { daemon.lastPolledAt }
    var lastError: String? { daemon.lastError }
    var isEnabled: Bool { AppSettings.shared.agentEnabled }

    func refresh() async {
        isRefreshing = true
        await daemon.refreshNow()
        isRefreshing = false
    }

    func dismiss(_ event: AgentEvent) {
        daemon.dismiss(event)
    }
}
