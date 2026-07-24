import Testing
import Foundation
@testable import houmao

struct MailImportanceTests {
    private func cluster(category: MailCategory, unsubscribe: Bool = false, count: Int = 1) -> MailCluster {
        let msgs = (0..<count).map {
            MailMessage(id: "\($0)", from: "a@x.com", subject: "s", hasListUnsubscribe: unsubscribe)
        }
        return MailCluster(primary: "x", category: category, messages: msgs)
    }

    @Test func promotionsIsRoutine() {
        #expect(MailImportance.isRoutine(cluster(category: .promotions)))
    }

    @Test func socialIsRoutine() {
        #expect(MailImportance.isRoutine(cluster(category: .social)))
    }

    @Test func allUnsubscribeIsRoutine() {
        #expect(MailImportance.isRoutine(cluster(category: .primary, unsubscribe: true, count: 2)))
    }

    @Test func personalIsNotRoutine() {
        #expect(!MailImportance.isRoutine(cluster(category: .personal)))
    }

    @Test func primaryIsNotRoutine() {
        #expect(!MailImportance.isRoutine(cluster(category: .primary)))
    }
}

struct MailWatcherParseTests {
    @Test func parsesThreeSentences() {
        let r = MailWatcher.parse("背景: 项目要上线\n目的: 通知发布计划\n处理: 需你今天确认")
        #expect(r == "背景：项目要上线\n目的：通知发布计划\n处理：需你今天确认")
    }

    @Test func parsesFullWidthColon() {
        let r = MailWatcher.parse("背景：例行周报\n目的：同步进度\n处理：无需处理")
        #expect(r == "背景：例行周报\n目的：同步进度\n处理：无需处理")
    }

    @Test func tolerantOfMissingLines() {
        let r = MailWatcher.parse("背景: 只有背景一行")
        #expect(r == "背景：只有背景一行")
    }

    @Test func fallsBackWhenUnstructured() {
        let r = MailWatcher.parse("就是一句话")
        #expect(r == "就是一句话")
    }
}
