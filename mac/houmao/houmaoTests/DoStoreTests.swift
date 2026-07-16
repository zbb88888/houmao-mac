import Testing
import Foundation
@testable import houmao

struct DoStoreTests {
    // MARK: - Active format

    @Test func parsesActiveWithCreatedDate() {
        let text = """
        # 工作

        ## todo
        - [ ] 写周报 <!--2026-07-02-->
        - [ ] 修 bug

        ## 学到老
        - [ ] 读 Swift 并发 <!--2026-07-01-->
        """
        let topics = DoStore.parseActive(text)
        #expect(topics.count == 2)
        #expect(topics[0].title == "todo")
        #expect(topics[0].items.count == 2)
        #expect(topics[0].items[0].text == "写周报")
        #expect(topics[0].items[0].done == false)
        #expect(DoStore.monthString(topics[0].items[0].createdAt) == "2026-07")
        #expect(topics[0].items[1].text == "修 bug")
        #expect(topics[1].items.count == 1)
    }

    @Test func activeRoundTripPreservesTextAndDate() {
        let topics = [
            DoTopic(title: "todo", items: [
                DoItem(text: "a", createdAt: makeDate("2026-07-02")),
                DoItem(text: "b", createdAt: makeDate("2026-07-05")),
            ]),
            DoTopic(title: "空的"),
        ]
        let serialized = DoStore.serializeActive(title: "工作", topics: topics)
        #expect(serialized.contains("- [ ] a <!--2026-07-02-->"))
        let reparsed = DoStore.parseActive(serialized)
        #expect(reparsed.count == 2)
        #expect(reparsed[0].items.map(\.text) == ["a", "b"])
        #expect(DoStore.monthString(reparsed[0].items[1].createdAt) == "2026-07")
        #expect(reparsed[1].title == "空的")
        #expect(reparsed[1].items.isEmpty)
    }

    @Test func activeRoundTripPreservesBody() {
        let topics = [
            DoTopic(title: "todo", items: [
                DoItem(text: "写周报", body: "要点：\n- 进度\n- 计划", createdAt: makeDate("2026-07-02")),
                DoItem(text: "无正文", createdAt: makeDate("2026-07-03")),
            ]),
        ]
        let serialized = DoStore.serializeActive(title: "工作", topics: topics)
        #expect(serialized.contains("  要点："))
        #expect(serialized.contains("  - 进度"))

        let reparsed = DoStore.parseActive(serialized)
        #expect(reparsed.count == 1)
        #expect(reparsed[0].items.count == 2)
        #expect(reparsed[0].items[0].text == "写周报")
        #expect(reparsed[0].items[0].body == "要点：\n- 进度\n- 计划")
        #expect(reparsed[0].items[1].text == "无正文")
        #expect(reparsed[0].items[1].body.isEmpty)
    }

    @Test func splitFullTextSeparatesTitleAndBody() {
        #expect(DoViewModel.splitFullText("标题").title == "标题")
        #expect(DoViewModel.splitFullText("标题").body.isEmpty)
        let both = DoViewModel.splitFullText("标题\n正文一\n正文二\n\n")
        #expect(both.title == "标题")
        #expect(both.body == "正文一\n正文二")
    }

    // MARK: - Archive format

    @Test func archiveRoundTripRecordsStartAndEnd() {
        let topics = [
            DoTopic(title: "todo", items: [
                DoItem(text: "写周报", createdAt: makeDate("2026-07-02"), completedAt: makeDate("2026-07-05")),
            ]),
        ]
        let out = DoStore.serializeArchive(title: "工作", month: "2026-07", topics: topics)
        #expect(out.contains("# 工作 · 归档 2026-07"))
        #expect(out.contains("- 写周报 · 起 2026-07-02 · 止 2026-07-05"))

        let reparsed = DoStore.parseArchive(out)
        #expect(reparsed.count == 1)
        #expect(reparsed[0].items.count == 1)
        let item = reparsed[0].items[0]
        #expect(item.text == "写周报")
        #expect(item.done)
        #expect(DoStore.monthString(item.createdAt) == "2026-07")
        #expect(DoStore.monthString(item.completedAt!) == "2026-07")
    }

    @Test func archiveSkipsEmptyTopics() {
        let out = DoStore.serializeArchive(
            title: "工作", month: "2026-07",
            topics: [DoTopic(title: "空"), DoTopic(title: "todo", items: [
                DoItem(text: "x", createdAt: makeDate("2026-07-01"), completedAt: makeDate("2026-07-02")),
            ])]
        )
        #expect(!out.contains("## 空"))
        #expect(out.contains("## todo"))
    }

    // MARK: - Disk (active save/load + legacy migration)

    @Test func loadImportsLegacyOpenItemsWhenActiveMissing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("do-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy = "# 工作\n\n## todo\n- [ ] 保留项\n- [x] 已完成应丢弃\n"
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("work.md"))

        let store = DoStore(directory: dir)
        let topics = store.load(.work)
        #expect(topics.count == 1)
        #expect(topics[0].items.map(\.text) == ["保留项"])
    }

    @Test func saveThenLoadActiveOnDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("do-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DoStore(directory: dir)
        try store.save(.work, topics: [DoTopic(title: "todo", items: [DoItem(text: "hi")])])
        let loaded = store.load(.work)
        #expect(loaded.count == 1)
        #expect(loaded[0].items[0].text == "hi")
    }

    // MARK: - Helpers

    private func makeDate(_ ymd: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: ymd)!
    }
}
