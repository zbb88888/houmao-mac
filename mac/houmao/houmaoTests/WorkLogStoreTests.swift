import Testing
import Foundation
@testable import houmao

struct WorkLogStoreTests {
    private func sampleItem(summary: String = "修复了登录超时的问题，并补了单测") -> WorkItem {
        WorkItem(
            kind: .pr,
            number: 1234,
            repoSlug: "acme/widgets",
            title: "Fix login timeout",
            url: "https://github.com/acme/widgets/pull/1234",
            createdAt: WorkItem.iso8601.date(from: "2026-07-02T09:30:00Z")!,
            summary: summary
        )
    }

    @Test func roundTripsAnItem() {
        let item = sampleItem()
        let parsed = WorkLogStore.parse(WorkLogStore.serialize(item))
        #expect(parsed == item)
    }

    @Test func serializesHeaderThenSummary() {
        let text = WorkLogStore.serialize(sampleItem())
        #expect(text.hasPrefix("---\n"))
        #expect(text.contains("kind: pr"))
        #expect(text.contains("number: 1234"))
        #expect(text.contains("repo: acme/widgets"))
        #expect(text.hasSuffix("修复了登录超时的问题，并补了单测"))
    }

    @Test func multilineSummaryIsPreserved() {
        let item = sampleItem(summary: "第一行\n第二行")
        let parsed = WorkLogStore.parse(WorkLogStore.serialize(item))
        #expect(parsed?.summary == "第一行\n第二行")
    }

    @Test func rejectsFileWithoutHeader() {
        #expect(WorkLogStore.parse("no header here\njust text") == nil)
    }

    @Test func rejectsHeaderMissingRequiredFields() {
        let text = """
        ---
        kind: pr
        number: 5
        ---
        缺少 repo/url/created 等字段
        """
        #expect(WorkLogStore.parse(text) == nil)
    }

    @Test func monthKeyIsUTCBucket() {
        // 2026-07-02T09:30:00Z → 2026-07 regardless of local zone.
        #expect(sampleItem().monthKey == "2026-07")
    }
}

@MainActor
struct WorkLogPeriodTests {
    @Test func quarterBucketsByMonth() {
        #expect(WorkLogViewModel.bucket(for: "2026-01", kind: .quarter)?.key == "2026-Q1")
        #expect(WorkLogViewModel.bucket(for: "2026-03", kind: .quarter)?.key == "2026-Q1")
        #expect(WorkLogViewModel.bucket(for: "2026-04", kind: .quarter)?.key == "2026-Q2")
        #expect(WorkLogViewModel.bucket(for: "2026-12", kind: .quarter)?.key == "2026-Q4")
    }

    @Test func halfAndYearBuckets() {
        #expect(WorkLogViewModel.bucket(for: "2026-06", kind: .half)?.key == "2026-H1")
        #expect(WorkLogViewModel.bucket(for: "2026-07", kind: .half)?.key == "2026-H2")
        #expect(WorkLogViewModel.bucket(for: "2026-09", kind: .year)?.key == "2026")
    }

    @Test func rejectsMalformedMonth() {
        #expect(WorkLogViewModel.bucket(for: "2026", kind: .quarter) == nil)
        #expect(WorkLogViewModel.bucket(for: "2026-13", kind: .quarter) == nil)
    }
}
