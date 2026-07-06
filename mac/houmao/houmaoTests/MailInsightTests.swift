//
//  MailInsightTests.swift
//  houmaoTests
//

import Testing
import Foundation
@testable import houmao

struct MailInsightTests {

    @Test func parseCleanJSON() throws {
        let reply = #"{"summary": "促销邮件", "importance": "low", "suggestDelete": true}"#
        let insight = try MailInsightAnalyzer.parse(reply)
        #expect(insight.summary == "促销邮件")
        #expect(insight.importance == .low)
        #expect(insight.suggestDelete == true)
    }

    @Test func parseJSONWrappedInProseAndFences() throws {
        let reply = """
        好的，分析结果如下：
        ```json
        {"summary": "账单通知", "importance": "high", "suggestDelete": false}
        ```
        以上。
        """
        let insight = try MailInsightAnalyzer.parse(reply)
        #expect(insight.summary == "账单通知")
        #expect(insight.importance == .high)
        #expect(insight.suggestDelete == false)
    }

    @Test func parseThrowsWhenNoJSON() {
        #expect(throws: MailProviderError.self) {
            try MailInsightAnalyzer.parse("抱歉，我无法处理。")
        }
    }

    @Test func parseThrowsOnMalformedJSON() {
        #expect(throws: MailProviderError.self) {
            try MailInsightAnalyzer.parse(#"{"summary": "x", "importance": "urgent"}"#)
        }
    }

    @Test func promptIncludesSampleFields() {
        let sample = MailMessage(
            id: "1", from: "shop@example.com", subject: "限时 5 折",
            snippet: "全场清仓", labelIds: ["CATEGORY_PROMOTIONS"]
        )
        let prompt = MailInsightAnalyzer.prompt(for: sample, category: .promotions, count: 12)
        #expect(prompt.contains("shop@example.com"))
        #expect(prompt.contains("限时 5 折"))
        #expect(prompt.contains("全场清仓"))
        #expect(prompt.contains("12"))
        #expect(prompt.contains("促销"))
    }
}
