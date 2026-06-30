//
//  PipelineParserTests.swift
//  houmaoTests
//

import Testing
import Foundation
@testable import houmao

struct PipelineParserTests {

    @Test func plainTextIsNotAPipeline() {
        #expect(PipelineParser.parse("hello world") == nil)
        #expect(PipelineParser.parse("translate this") == nil)
        #expect(PipelineParser.parse("") == nil)
    }

    @Test func singleActionFromClipboard() {
        let pipeline = PipelineParser.parse("$translate")
        #expect(pipeline?.stages == [.action("translate")])
        #expect(pipeline?.actionNames == ["translate"])
    }

    @Test func literalThenActions() {
        let pipeline = PipelineParser.parse("你好世界 | $translate | $save")
        #expect(pipeline?.stages == [
            .literal("你好世界"),
            .action("translate"),
            .action("save"),
        ])
        #expect(pipeline?.actionNames == ["translate", "save"])
    }

    @Test func actionsOnly() {
        let pipeline = PipelineParser.parse("$summarize | $save")
        #expect(pipeline?.stages == [.action("summarize"), .action("save")])
    }

    @Test func whitespaceAroundSeparatorsIsTrimmed() {
        let pipeline = PipelineParser.parse("  text   |   $translate  ")
        #expect(pipeline?.stages == [.literal("text"), .action("translate")])
    }

    @Test func emptySegmentsAreDropped() {
        let pipeline = PipelineParser.parse("text || $translate |")
        #expect(pipeline?.stages == [.literal("text"), .action("translate")])
    }

    @Test func dollarFollowedByNonIdentifierIsLiteral() {
        // "$5" and "$ note" are not valid action names → treated as literal.
        #expect(PipelineParser.parse("$5 dollars") == nil)
        let pipeline = PipelineParser.parse("$5 | $save")
        #expect(pipeline?.stages == [.literal("$5"), .action("save")])
    }

    @Test func underscoresAndDigitsAllowedInActionName() {
        #expect(PipelineParser.isValidActionName("save_note2"))
        #expect(PipelineParser.isValidActionName("_internal"))
        #expect(!PipelineParser.isValidActionName("2cool"))
        #expect(!PipelineParser.isValidActionName("has space"))
        #expect(!PipelineParser.isValidActionName(""))
    }
}
