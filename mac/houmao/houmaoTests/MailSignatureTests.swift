import Testing
import Foundation
@testable import houmao

struct MailSignatureTests {
    private func msg(_ id: String) -> MailMessage {
        MailMessage(id: id, from: "a@x.com", subject: "hi")
    }

    private func cluster(_ messages: [MailMessage]) -> MailCluster {
        MailCluster(primary: "未分类", category: .primary, messages: messages)
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
}
