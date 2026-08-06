import Testing
import Foundation
@testable import houmao

/// Records ids passed to `trashMessages` for assertions.
private actor TrashRecorder {
    private(set) var trashed: [String] = []
    func record(_ ids: [String]) { trashed += ids }
}

/// In-memory `MailProvider` for tool tests. Read paths return canned data;
/// `trashMessages` records into an optional recorder.
private struct FakeMailProvider: MailProvider {
    var ids: [String] = []
    var metadata: [MailMessage] = []
    var full: MailMessageDetail?
    var trashRecorder: TrashRecorder?

    func listMessages(query: String, maxResults: Int) async throws -> [String] { ids }
    func fetchMetadata(ids: [String]) async throws -> [MailMessage] { metadata }
    func fetchFull(id: String) async throws -> MailMessageDetail {
        guard let full else { throw MailProviderError.requestFailed("no detail") }
        return full
    }
    func trashMessages(ids: [String]) async throws { await trashRecorder?.record(ids) }
    func untrash(ids: [String]) async throws {}
    func markRead(ids: [String]) async throws {}
    func markUnread(ids: [String]) async throws {}
}

private let epoch = Date(timeIntervalSince1970: 0)

/// A `MailMemoryStore` in a throwaway temp directory, so triage tests never
/// touch the real `~/Documents/houmao/mail` cache.
private func tmpMemory() -> MailMemoryStore {
    MailMemoryStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("houmao-test-\(UUID().uuidString)", isDirectory: true))
}

/// Counts how many times the injected summarizer actually ran.
private actor CallCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

@Test func listRecentMailFormatsNewestFirst() async throws {
    let provider = FakeMailProvider(
        ids: ["a", "b"],
        metadata: [
            MailMessage(id: "a", from: "old@x.com", subject: "Old", snippet: "s1", date: epoch),
            MailMessage(id: "b", from: "new@x.com", subject: "New", snippet: "s2", date: epoch.addingTimeInterval(100)),
        ]
    )
    let out = try await ListRecentMailTool(provider: provider).invoke(arguments: .object([:]))
    // Newest ("New") must appear before "Old".
    let newIdx = try #require(out.range(of: "New"))
    let oldIdx = try #require(out.range(of: "Old"))
    #expect(newIdx.lowerBound < oldIdx.lowerBound)
    #expect(out.contains("[id: b]"))
}

@Test func listRecentMailReportsEmpty() async throws {
    let out = try await ListRecentMailTool(provider: FakeMailProvider()).invoke(arguments: .object([:]))
    #expect(out.contains("No messages found"))
}

@Test func readMailReturnsBody() async throws {
    let provider = FakeMailProvider(full: MailMessageDetail(
        id: "a", from: "x@y.com", to: "me@z.com", subject: "Hi", date: "2026-08-05", body: "hello world"
    ))
    let out = try await ReadMailTool(provider: provider).invoke(arguments: .object(["id": .string("a")]))
    #expect(out.contains("subject: Hi"))
    #expect(out.contains("hello world"))
}

@Test func readMailMissingIdReturnsError() async throws {
    let out = try await ReadMailTool(provider: FakeMailProvider()).invoke(arguments: .object([:]))
    #expect(out.contains("missing required argument"))
}

// MARK: - trash_mail (mutating)

@Test func trashMailIsMarkedMutating() {
    #expect(TrashMailTool(provider: FakeMailProvider()).isMutating)
}

@Test func trashMailMovesAndRecordsIds() async throws {
    let recorder = TrashRecorder()
    let tool = TrashMailTool(provider: FakeMailProvider(trashRecorder: recorder))
    let out = try await tool.invoke(arguments: .object(["ids": .array([.string("a"), .string("b")])]))
    #expect(out.contains("2"))
    #expect(await recorder.trashed == ["a", "b"])
}

@Test func trashMailEmptyReturnsError() async throws {
    let out = try await TrashMailTool(provider: FakeMailProvider()).invoke(arguments: .object([:]))
    #expect(out.contains("error"))
}

// MARK: - triage_inbox

@Test func triageDropsRoutineAndSummarizesImportant() async throws {
    let provider = FakeMailProvider(
        ids: ["a", "b"],
        metadata: [
            MailMessage(id: "a", from: "ops@x.com", subject: "Server down alert", snippet: "prod down", date: epoch.addingTimeInterval(100)),
            MailMessage(id: "b", from: "deals@shop.com", subject: "50 percent off everything", snippet: "sale", hasListUnsubscribe: true, date: epoch),
        ]
    )
    let tool = TriageInboxTool(provider: provider, customTags: [], memory: tmpMemory(), summarize: { _ in "背景: 系统告警" })
    let out = try await tool.invoke(arguments: .object([:]))
    #expect(out.contains("Server down alert"))
    #expect(out.contains("系统告警"))
    #expect(!out.contains("50 percent off"))
    #expect(out.contains("已忽略 1 组噪音"))
}

@Test func triageReportsWhenAllRoutine() async throws {
    let provider = FakeMailProvider(
        ids: ["b"],
        metadata: [
            MailMessage(id: "b", from: "deals@shop.com", subject: "50 percent off everything", snippet: "sale", hasListUnsubscribe: true, date: epoch),
        ]
    )
    let tool = TriageInboxTool(provider: provider, customTags: [], memory: tmpMemory(), summarize: { _ in "x" })
    let out = try await tool.invoke(arguments: .object([:]))
    #expect(out.contains("没有需要关注的重点"))
}
@Test func triageCachesSummariesAcrossCalls() async throws {
    let memory = tmpMemory()
    let counter = CallCounter()
    let provider = FakeMailProvider(
        ids: ["a"],
        metadata: [
            MailMessage(id: "a", from: "ops@x.com", subject: "Server down alert", snippet: "prod down", date: epoch),
        ]
    )
    let summarize: @Sendable (MailCluster) async -> String? = { _ in await counter.bump(); return "背景: x" }
    let tool = TriageInboxTool(provider: provider, customTags: [], memory: memory, summarize: summarize)
    _ = try await tool.invoke(arguments: .object([:]))
    _ = try await tool.invoke(arguments: .object([:]))
    // Same cluster (same message ids) the second time → cache hit → no new summary.
    #expect(await counter.count == 1)
}