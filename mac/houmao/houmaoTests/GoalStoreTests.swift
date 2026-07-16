import Testing
import Foundation
@testable import houmao

struct GoalStoreTests {
    @Test func parsesTitleFromHeadingThenFirstLine() {
        #expect(GoalDoc.parseTitle("# 学会游泳\n正文", fallback: "x") == "学会游泳")
        #expect(GoalDoc.parseTitle("没有标题的第一行\n第二行", fallback: "x") == "没有标题的第一行")
        #expect(GoalDoc.parseTitle("", fallback: "回退") == "回退")
    }

    @Test func extractsMermaidBlock() {
        let md = """
        # 目标

        描述

        ```mermaid
        flowchart TD
            A --> B
        ```
        """
        #expect(GoalDoc.parseMermaid(md) == "flowchart TD\n    A --> B")
    }

    @Test func noMermaidReturnsNil() {
        #expect(GoalDoc.parseMermaid("# 目标\n只有正文") == nil)
        // A plain code block that isn't mermaid is ignored.
        #expect(GoalDoc.parseMermaid("```swift\nlet x = 1\n```") == nil)
    }

    @Test func saveThenLoadRoundTrips() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goal-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GoalStore(directory: dir)

        store.saveManifest(.work, topicTitles: ["目标"])
        store.saveGoal(.work, topic: "目标", id: "goal-1", markdown: "# 甲\n```mermaid\nflowchart TD\nA-->B\n```")
        store.saveGoal(.work, topic: "目标", id: "goal-2", markdown: "# 乙\n正文")

        let topics = store.loadTopics(.work)
        #expect(topics.map(\.title) == ["目标"])
        let goals = topics.first?.goals ?? []
        #expect(goals.count == 2)
        #expect(goals.map(\.title) == ["甲", "乙"])          // sorted by title (pinyin: jiǎ < yǐ)
        #expect(goals.first(where: { $0.id == "goal-1" })?.mermaid == "flowchart TD\nA-->B")
    }

    @Test func manifestRoundTrips() {
        let text = GoalStore.serializeManifest(title: "工作", topicTitles: ["todo", "学到老"])
        #expect(GoalStore.parseManifest(text) == ["todo", "学到老"])
        // Non-`- ` lines (the title header) are ignored; duplicates dropped.
        #expect(GoalStore.parseManifest("# 工作\n- a\n- a\n- b") == ["a", "b"])
    }

    @Test func manifestPreservesEmptyTopicAndOrder() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goal-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GoalStore(directory: dir)

        // Two topics in manifest order; only the second has a goal on disk.
        store.saveManifest(.life, topicTitles: ["空主题", "有目标"])
        store.saveGoal(.life, topic: "有目标", id: "g1", markdown: "# X")

        let topics = store.loadTopics(.life)
        #expect(topics.map(\.title) == ["空主题", "有目标"])   // manifest order preserved
        #expect(topics.first?.goals.isEmpty == true)          // empty topic survives
        #expect(topics.last?.goals.count == 1)
    }

    @Test func migratesFlatGoals() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goal-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = GoalStore(directory: dir)

        // Simulate the pre-topics layout: a flat `.md` at the goals root.
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data("# 老目标".utf8).write(to: dir.appendingPathComponent("goal-old.md"))

        let moved = store.migrateFlatGoals(into: .work, topic: "目标")
        #expect(moved == 1)

        let topics = store.loadTopics(.work)
        #expect(topics.first(where: { $0.title == "目标" })?.goals.map(\.title) == ["老目标"])
    }
}
