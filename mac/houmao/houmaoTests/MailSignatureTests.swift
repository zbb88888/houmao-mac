import Testing
import Foundation
@testable import houmao

struct MailSignatureTests {
    private func msg(_ id: String, from: String = "a@x.com", subject: String = "hi") -> MailMessage {
        MailMessage(id: id, from: from, subject: subject)
    }

    private func cluster(_ messages: [MailMessage], primary: String = "未分类") -> MailCluster {
        MailCluster(primary: primary, category: .primary, messages: messages)
    }

    @Test func clusterSignatureIsOrderInvariant() {
        let a = cluster([msg("1"), msg("2"), msg("3")])
        let b = cluster([msg("3"), msg("1"), msg("2")])
        #expect(MailSignature.cluster(a) == MailSignature.cluster(b))
    }

    @Test func clusterSignatureDiffersByMembers() {
        let a = cluster([msg("1"), msg("2")])
        let b = cluster([msg("1"), msg("2"), msg("3")])
        #expect(MailSignature.cluster(a) != MailSignature.cluster(b))
    }

    @Test func familyIgnoresDigitsInSubject() {
        let a = cluster([msg("1", from: "News <news@site.com>", subject: "Daily report 7/21")])
        let b = cluster([msg("2", from: "News <news@site.com>", subject: "Daily report 7/22")])
        #expect(MailSignature.family(a) == MailSignature.family(b))
    }

    @Test func familyDiffersBySender() {
        let a = cluster([msg("1", from: "news@a.com", subject: "Report")])
        let b = cluster([msg("2", from: "news@b.com", subject: "Report")])
        #expect(MailSignature.family(a) != MailSignature.family(b))
    }

    @Test func normalizeSubjectCollapsesDigitsAndSpace() {
        #expect(MailSignature.normalizeSubject("Daily  Report 2026") == "daily report")
    }
}
