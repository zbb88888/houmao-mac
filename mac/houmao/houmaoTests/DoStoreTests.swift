import Testing
@testable import houmao

struct DoStoreTests {
    @Test func parsesTopicsAndCheckboxes() {
        let text = """
        # 工作

        ## todo
        - [ ] 写周报
        - [x] 修复登录 bug

        ## 学到老
        - [ ] 读 Swift 并发
        """
        let topics = DoStore.parse(text)
        #expect(topics.count == 2)
        #expect(topics[0].title == "todo")
        #expect(topics[0].items.count == 2)
        #expect(topics[0].items[0].text == "写周报")
        #expect(topics[0].items[0].done == false)
        #expect(topics[0].items[1].done == true)
        #expect(topics[1].title == "学到老")
        #expect(topics[1].items.count == 1)
    }

    @Test func parsesEmptyTopic() {
        let text = """
        # 生活

        ## 衣食住行

        ## 吃喝玩乐
        - [ ] 周末爬山
        """
        let topics = DoStore.parse(text)
        #expect(topics.count == 2)
        #expect(topics[0].title == "衣食住行")
        #expect(topics[0].items.isEmpty)
        #expect(topics[1].items.count == 1)
    }

    @Test func ignoresJunkAndItemsWithoutTopic() {
        let text = """
        # 工作
        - [ ] 无归属的项应被忽略
        随手写的一句话
        ## todo
        - [ ] 有效项
        not a task line
        """
        let topics = DoStore.parse(text)
        #expect(topics.count == 1)
        #expect(topics[0].items.count == 1)
        #expect(topics[0].items[0].text == "有效项")
    }

    @Test func uppercaseXIsDone() {
        let topics = DoStore.parse("## t\n- [X] done\n")
        #expect(topics[0].items[0].done == true)
    }

    @Test func roundTripPreservesContent() {
        let topics = [
            DoTopic(title: "todo", items: [
                DoItem(text: "a", done: false),
                DoItem(text: "b", done: true),
            ]),
            DoTopic(title: "空的"),
        ]
        let serialized = DoStore.serialize(title: "工作", topics: topics)
        let reparsed = DoStore.parse(serialized)
        #expect(reparsed.count == 2)
        #expect(reparsed[0].title == "todo")
        #expect(reparsed[0].items.map(\.text) == ["a", "b"])
        #expect(reparsed[0].items.map(\.done) == [false, true])
        #expect(reparsed[1].title == "空的")
        #expect(reparsed[1].items.isEmpty)
    }

    @Test func serializeUsesCheckboxSyntax() {
        let out = DoStore.serialize(
            title: "工作",
            topics: [DoTopic(title: "todo", items: [DoItem(text: "x", done: true)])]
        )
        #expect(out.contains("# 工作"))
        #expect(out.contains("## todo"))
        #expect(out.contains("- [x] x"))
    }
}
