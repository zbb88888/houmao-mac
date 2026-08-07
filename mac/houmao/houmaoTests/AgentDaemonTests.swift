import Testing
import Foundation
@testable import houmao

/// A Watcher whose poll result is swappable (and can be made to fail).
private final class StubWatcher: Watcher, @unchecked Sendable {
    let id: String
    private let lock = NSLock()
    private var result: Result<[AgentEvent], Error>
    init(id: String, _ result: Result<[AgentEvent], Error> = .success([])) {
        self.id = id
        self.result = result
    }
    func set(_ r: Result<[AgentEvent], Error>) { lock.lock(); result = r; lock.unlock() }
    func poll() async throws -> [AgentEvent] {
        lock.lock(); let r = result; lock.unlock()
        return try r.get()
    }
}

private struct StubError: Error {}

private func ev(_ id: String, _ kind: AgentEvent.Kind = .assignedIssue) -> AgentEvent {
    AgentEvent(
        id: id, kind: kind, title: id, subtitle: "owner/repo", url: id,
        detectedAt: Date(timeIntervalSince1970: 1_700_000_000), suggestedCommand: "/issue \(id)"
    )
}

private func tmpStore() -> AgentStore {
    AgentStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("houmao-daemon-test-\(UUID().uuidString)", isDirectory: true))
}

@MainActor @Test func refreshRemovesVanishedItems() async {
    AppSettings.shared.agentGitHubWatcherEnabled = true
    let gh = StubWatcher(id: "github", .success([ev("a"), ev("b")]))
    let daemon = AgentDaemon(watchers: [gh], store: tmpStore())
    await daemon.refreshNow()
    #expect(Set(daemon.events.map(\.id)) == ["a", "b"])
    gh.set(.success([ev("a")]))  // "b" reviewed/closed → gone from the source
    await daemon.refreshNow()
    #expect(daemon.events.map(\.id) == ["a"])
}

@MainActor @Test func refreshKeepsItemsWhenWatcherFails() async {
    AppSettings.shared.agentGitHubWatcherEnabled = true
    let gh = StubWatcher(id: "github", .success([ev("a")]))
    let daemon = AgentDaemon(watchers: [gh], store: tmpStore())
    await daemon.refreshNow()
    #expect(daemon.events.map(\.id) == ["a"])
    gh.set(.failure(StubError()))  // transient failure must not wipe the list
    await daemon.refreshNow()
    #expect(daemon.events.map(\.id) == ["a"])
}

@MainActor @Test func refreshDoesNotResurrectDismissed() async {
    AppSettings.shared.agentGitHubWatcherEnabled = true
    let gh = StubWatcher(id: "github", .success([ev("a")]))
    let daemon = AgentDaemon(watchers: [gh], store: tmpStore())
    await daemon.refreshNow()
    daemon.dismiss(ev("a"))
    #expect(daemon.events.isEmpty)
    await daemon.refreshNow()  // source still returns "a"
    #expect(daemon.events.isEmpty)
}
