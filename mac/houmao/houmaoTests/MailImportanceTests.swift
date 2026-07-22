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
    @Test func parsesImportantYes() {
        let r = MailWatcher.parse("重点: 是\n摘要: 老板要你今天回复")
        #expect(r.important)
        #expect(r.summary == "老板要你今天回复")
    }

    @Test func parsesImportantNoFullWidthColon() {
        let r = MailWatcher.parse("重点：否\n摘要：例行周报")
        #expect(!r.important)
        #expect(r.summary == "例行周报")
    }

    @Test func fallsBackWhenUnstructured() {
        let r = MailWatcher.parse("就是一句话")
        #expect(!r.important)
        #expect(r.summary == "就是一句话")
    }
}
