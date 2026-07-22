import Testing
import Foundation
@testable import houmao

struct AgentStoreTests {
    private func event(_ id: String, kind: AgentEvent.Kind = .assignedIssue) -> AgentEvent {
        AgentEvent(
            id: id, kind: kind, title: "标题 \(id)", subtitle: "owner/repo",
            url: id, detectedAt: Date(timeIntervalSince1970: 1_700_000_000),
            suggestedCommand: "/issue \(id)"
        )
    }

    @Test func roundTripsEventsAndSeen() throws {
        let state = AgentStore.State(
            events: [event("a", kind: .reviewRequestedPR), event("b")],
            seen: ["a", "b", "c"]
        )
        let data = try AgentStore.encode(state)
        let decoded = try AgentStore.decode(data)
        #expect(decoded == state)
    }

    @Test func decodesEmptyState() throws {
        let data = try AgentStore.encode(.empty)
        #expect(try AgentStore.decode(data) == .empty)
    }

    @Test func loadReturnsEmptyWhenFileMissing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("houmao-agent-test-\(UUID().uuidString)", isDirectory: true)
        let store = AgentStore(directory: dir)
        #expect(store.load() == .empty)
    }

    @Test func savedStateReloads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("houmao-agent-test-\(UUID().uuidString)", isDirectory: true)
        let store = AgentStore(directory: dir)
        let state = AgentStore.State(events: [event("x")], seen: ["x"])
        try store.save(state)
        #expect(store.load() == state)
        try? FileManager.default.removeItem(at: dir)
    }
}
