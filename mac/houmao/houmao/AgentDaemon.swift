import Foundation
import Observation
import os.log

private let agentLog = Logger(subsystem: "com.houmao", category: "Agent")

/// The proactive agent's resident background loop (主观能动性).
///
/// On a timer, if the policy allows (enabled + outside quiet hours), it senses
/// each enabled watcher, decides which items are new (via `AgentDiff`), and
/// surfaces them — a local notification plus an inbox entry. It never acts on an
/// item; acting is always an explicit user step from the inbox. Owns the
/// persisted state; the inbox UI reads it through `AgentViewModel`.
@MainActor
@Observable
final class AgentDaemon {
    /// Surfaced, not-yet-dismissed events, newest first (drives the inbox).
    private(set) var events: [AgentEvent] = []
    /// When the most recent poll completed (for the inbox status line).
    private(set) var lastPolledAt: Date?
    /// The most recent watcher error, if any (surfaced in the inbox).
    private(set) var lastError: String?

    /// Every id ever surfaced, so dismissed / restarted items aren't re-notified.
    private var seen: Set<String> = []
    private let store: AgentStore
    private let watchers: [Watcher]
    private var timer: Timer?
    private var isPolling = false

    /// Called on the main actor when brand-new events are surfaced, so the shell
    /// can post a local notification (kept out of Core; injected by the app).
    var onNewEvents: (@MainActor ([AgentEvent]) -> Void)?

    init(watchers: [Watcher] = [GitHubWatcher()], store: AgentStore = AgentStore()) {
        self.watchers = watchers
        self.store = store
        let state = store.load()
        events = state.events
        seen = Set(state.seen)
    }

    /// Build the current policy from user settings.
    static func policy() -> AgentPolicy {
        let s = AppSettings.shared
        return AgentPolicy(
            isEnabled: s.agentEnabled,
            intervalMinutes: s.agentIntervalMinutes,
            quietStartHour: s.agentQuietStartHour,
            quietEndHour: s.agentQuietEndHour,
            maxPerPoll: AgentPolicy.default.maxPerPoll
        )
    }

    /// (Re)configure the loop from current settings: schedule (or cancel) the
    /// poll timer. Call on launch and whenever agent settings change. When
    /// enabled, polls once shortly after so results appear without waiting a
    /// full interval.
    func applyPolicy() {
        timer?.invalidate()
        timer = nil
        let policy = Self.policy()
        guard policy.isEnabled else { return }
        let interval = TimeInterval(max(1, policy.intervalMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollIfAllowed() }
        }
        Task { @MainActor in await pollIfAllowed() }
    }

    /// Poll only when the policy currently allows it (used by the timer).
    func pollIfAllowed() async {
        guard Self.policy().allowsPoll(at: Date()) else { return }
        await pollNow()
    }

    /// Force a poll now regardless of the quiet-hours gate (the inbox 刷新
    /// button). Still limited to the enabled watchers.
    func refreshNow() async {
        await pollNow()
    }

    private func pollNow() async {
        guard !isPolling else { return }
        isPolling = true
        defer { isPolling = false }

        var polled: [AgentEvent] = []
        var pollError: String?
        for watcher in enabledWatchers() {
            do {
                polled += try await watcher.poll()
            } catch {
                pollError = error.localizedDescription
                agentLog.error("watcher \(watcher.id, privacy: .public) poll failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        lastError = pollError
        lastPolledAt = Date()

        let fresh = AgentDiff.newEvents(current: polled, seen: seen)
        guard !fresh.isEmpty else { persist(); return }
        for event in fresh { seen.insert(event.id) }
        events.insert(contentsOf: fresh, at: 0)
        persist()

        let capped = Array(fresh.prefix(Self.policy().maxPerPoll))
        onNewEvents?(capped)
    }

    /// Remove an event from the inbox. It stays in `seen`, so it isn't surfaced
    /// again.
    func dismiss(_ event: AgentEvent) {
        events.removeAll { $0.id == event.id }
        persist()
    }

    private func enabledWatchers() -> [Watcher] {
        watchers.filter { watcher in
            switch watcher.id {
            case "github": return AppSettings.shared.agentGitHubWatcherEnabled
            default: return true
            }
        }
    }

    private func persist() {
        let state = AgentStore.State(events: events, seen: Array(seen))
        do {
            try store.save(state)
        } catch {
            agentLog.error("persist agent state failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
