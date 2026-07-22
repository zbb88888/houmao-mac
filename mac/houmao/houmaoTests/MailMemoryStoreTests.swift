import Testing
import Foundation
@testable import houmao

struct MailMemoryStoreTests {
    @Test func roundTrips() throws {
        let state = MailMemoryStore.State(
            summaries: ["sigA": "一句话摘要", "sigB": "another"],
            seenClusters: ["sigA", "sigC"],
            seenFamilies: ["news@x.com|report"]
        )
        let decoded = try MailMemoryStore.decode(MailMemoryStore.encode(state))
        #expect(decoded == state)
    }

    @Test func decodesEmpty() throws {
        #expect(try MailMemoryStore.decode(MailMemoryStore.encode(.empty)) == .empty)
    }

    @Test func isSeenMatchesClusterOrFamily() {
        let state = MailMemoryStore.State(
            summaries: [:],
            seenClusters: ["sig1"],
            seenFamilies: ["fam1"]
        )
        #expect(MailMemoryStore.isSeen(state, clusterSig: "sig1", familyKey: "other"))
        #expect(MailMemoryStore.isSeen(state, clusterSig: "other", familyKey: "fam1"))
        #expect(!MailMemoryStore.isSeen(state, clusterSig: "x", familyKey: "y"))
    }

    @Test func loadReturnsEmptyWhenMissing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("houmao-mail-test-\(UUID().uuidString)", isDirectory: true)
        #expect(MailMemoryStore(directory: dir).load() == .empty)
    }

    @Test func savedStateReloads() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("houmao-mail-test-\(UUID().uuidString)", isDirectory: true)
        let store = MailMemoryStore(directory: dir)
        let state = MailMemoryStore.State(summaries: ["s": "m"], seenClusters: ["s"], seenFamilies: ["f"])
        try store.save(state)
        #expect(store.load() == state)
        try? FileManager.default.removeItem(at: dir)
    }
}
