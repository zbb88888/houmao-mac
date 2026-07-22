import Testing
import Foundation
@testable import houmao

struct AgentDiffTests {
    private func event(_ id: String) -> AgentEvent {
        AgentEvent(
            id: id, kind: .assignedIssue, title: "t", subtitle: "owner/repo",
            url: id, detectedAt: Date(timeIntervalSince1970: 0), suggestedCommand: "/issue \(id)"
        )
    }

    @Test func returnsOnlyUnseen() {
        let current = [event("a"), event("b"), event("c")]
        let fresh = AgentDiff.newEvents(current: current, seen: ["b"])
        #expect(fresh.map(\.id) == ["a", "c"])
    }

    @Test func deduplicatesWithinCurrent() {
        let current = [event("a"), event("a"), event("b")]
        let fresh = AgentDiff.newEvents(current: current, seen: [])
        #expect(fresh.map(\.id) == ["a", "b"])
    }

    @Test func emptyWhenAllSeen() {
        let current = [event("a"), event("b")]
        #expect(AgentDiff.newEvents(current: current, seen: ["a", "b"]).isEmpty)
    }

    @Test func emptyInputYieldsEmpty() {
        #expect(AgentDiff.newEvents(current: [], seen: ["a"]).isEmpty)
    }
}
