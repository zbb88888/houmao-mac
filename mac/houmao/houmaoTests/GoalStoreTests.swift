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

        try store.save(id: "goal-1", markdown: "# 甲\n```mermaid\nflowchart TD\nA-->B\n```")
        try store.save(id: "goal-2", markdown: "# 乙\n正文")

        let goals = store.load()
        #expect(goals.count == 2)
        #expect(goals.map(\.title) == ["甲", "乙"])          // sorted by title (pinyin: jiǎ < yǐ)
        #expect(goals.first(where: { $0.id == "goal-1" })?.mermaid == "flowchart TD\nA-->B")
    }
}
