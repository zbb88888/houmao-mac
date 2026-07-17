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
    private let now = WorkItem.iso8601.date(from: "2026-07-17T00:00:00Z")!

    @Test func weekWindowReachesSevenDaysBack() {
        #expect(WorkLogViewModel.cutoff(for: .week, now: now)
            == WorkItem.iso8601.date(from: "2026-07-10T00:00:00Z")!)
    }

    @Test func monthAndYearWindows() {
        #expect(WorkLogViewModel.cutoff(for: .month, now: now)
            == WorkItem.iso8601.date(from: "2026-06-17T00:00:00Z")!)
        #expect(WorkLogViewModel.cutoff(for: .year, now: now)
            == WorkItem.iso8601.date(from: "2025-07-17T00:00:00Z")!)
    }

    @Test func quarterHalfAndThreeQuarterWindows() {
        #expect(WorkLogViewModel.cutoff(for: .quarter, now: now)
            == WorkItem.iso8601.date(from: "2026-04-17T00:00:00Z")!)
        #expect(WorkLogViewModel.cutoff(for: .half, now: now)
            == WorkItem.iso8601.date(from: "2026-01-17T00:00:00Z")!)
        #expect(WorkLogViewModel.cutoff(for: .threeQuarter, now: now)
            == WorkItem.iso8601.date(from: "2025-10-17T00:00:00Z")!)
    }
}
