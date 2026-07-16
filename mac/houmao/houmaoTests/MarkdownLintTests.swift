import Testing
@testable import houmao

struct MarkdownLintTests {
    @Test func cleanDocumentHasNoIssues() {
        let text = """
        # 标题

        - 一
        - 二

        ```swift
        let x = 1
        ```
        """
        #expect(MarkdownLint.check(text).isEmpty)
    }

    @Test func flagsHeadingMissingSpace() {
        let issues = MarkdownLint.check("#标题")
        #expect(issues.contains { $0.line == 1 && $0.message.contains("标题 #") })
        #expect(MarkdownLint.check("# 标题").isEmpty)
        #expect(MarkdownLint.check("### 三级").isEmpty)
    }

    @Test func flagsListMarkerMissingSpace() {
        #expect(!MarkdownLint.check("-项").isEmpty)
        #expect(!MarkdownLint.check("1.项").isEmpty)
        #expect(MarkdownLint.check("- 项").isEmpty)
        #expect(MarkdownLint.check("1. 项").isEmpty)
    }

    @Test func ignoresEmphasisRulesAndDecimals() {
        #expect(MarkdownLint.check("*斜体*").isEmpty)
        #expect(MarkdownLint.check("---").isEmpty)
        #expect(MarkdownLint.check("1.5 公斤").isEmpty)
    }

    @Test func flagsUnclosedFence() {
        let issues = MarkdownLint.check("```\ncode\n")
        #expect(issues.contains { $0.message.contains("未闭合") })
    }

    @Test func skipsRulesInsideFence() {
        let text = "```\n#notheading\n\ttab ok\n```\n"
        #expect(MarkdownLint.check(text).isEmpty)
    }

    @Test func flagsTrailingWhitespaceTabAndEmptyLink() {
        #expect(MarkdownLint.check("文字 ").contains { $0.message.contains("行尾") })    // 1 space
        #expect(MarkdownLint.check("文字   ").contains { $0.message.contains("行尾") })  // 3 spaces
        #expect(MarkdownLint.check("文字  ").isEmpty)                                  // 2 spaces = hard break
        #expect(MarkdownLint.check("a\tb").contains { $0.message.contains("Tab") })
        #expect(MarkdownLint.check("[]()").contains { $0.message.contains("空链接") })
        #expect(MarkdownLint.check("[文字](url)").isEmpty)
    }
}
