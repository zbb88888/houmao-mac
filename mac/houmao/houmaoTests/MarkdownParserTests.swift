import Testing
@testable import houmao

/// Covers the pure, line-based `MarkdownParser`. Rendering is not exercised here
/// (that is SwiftUI), only the block segmentation the views depend on.
struct MarkdownParserTests {

    @Test func parsesAtxHeadings() {
        #expect(MarkdownParser.parse("# Title") == [.heading(level: 1, text: "Title")])
        #expect(MarkdownParser.parse("### Deep") == [.heading(level: 3, text: "Deep")])
        // A `#` without a trailing space is not a heading.
        #expect(MarkdownParser.parse("#notitle") == [.paragraph("#notitle")])
    }

    @Test func separatesParagraphsOnBlankLines() {
        let blocks = MarkdownParser.parse("first line\n\nsecond block")
        #expect(blocks == [.paragraph("first line"), .paragraph("second block")])
    }

    @Test func parsesFencedCodeBlockWithLanguage() {
        let source = "```swift\nlet x = 1\nlet y = 2\n```"
        #expect(MarkdownParser.parse(source) == [
            .codeBlock(language: "swift", code: "let x = 1\nlet y = 2")
        ])
    }

    @Test func unterminatedFenceStillRenders() {
        // A still-streaming code block (no closing fence) must not be dropped.
        let source = "```\npartial"
        #expect(MarkdownParser.parse(source) == [.codeBlock(language: nil, code: "partial")])
    }

    @Test func parsesUnorderedList() {
        let blocks = MarkdownParser.parse("- a\n- b")
        #expect(blocks == [.list(MarkdownList(ordered: false, items: [
            MarkdownListItem(text: "a", sublist: nil),
            MarkdownListItem(text: "b", sublist: nil),
        ]))])
    }

    @Test func parsesOrderedList() {
        let blocks = MarkdownParser.parse("1. one\n2. two")
        #expect(blocks == [.list(MarkdownList(ordered: true, items: [
            MarkdownListItem(text: "one", sublist: nil),
            MarkdownListItem(text: "two", sublist: nil),
        ]))])
    }

    @Test func parsesNestedList() {
        let blocks = MarkdownParser.parse("- top\n  - child\n- next")
        let expected: MarkdownBlock = .list(MarkdownList(ordered: false, items: [
            MarkdownListItem(text: "top", sublist: MarkdownList(ordered: false, items: [
                MarkdownListItem(text: "child", sublist: nil),
            ])),
            MarkdownListItem(text: "next", sublist: nil),
        ]))
        #expect(blocks == [expected])
    }

    @Test func parsesBlockquote() {
        let blocks = MarkdownParser.parse("> quoted\n> lines")
        #expect(blocks == [.quote([.paragraph("quoted\nlines")])])
    }

    @Test func parsesThematicBreak() {
        #expect(MarkdownParser.parse("---") == [.thematicBreak])
        #expect(MarkdownParser.parse("***") == [.thematicBreak])
    }

    @Test func parsesTable() {
        let source = "| a | b |\n| --- | --- |\n| 1 | 2 |\n| 3 | 4 |"
        #expect(MarkdownParser.parse(source) == [
            .table(header: ["a", "b"], rows: [["1", "2"], ["3", "4"]])
        ])
    }

    @Test func pipeWithoutDelimiterIsParagraph() {
        // A lone pipe line without a delimiter row is not a table.
        #expect(MarkdownParser.parse("a | b") == [.paragraph("a | b")])
    }
}
