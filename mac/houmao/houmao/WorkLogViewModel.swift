import Foundation

/// Drives the `/worklog` panel: a two-stage GitHub work-log summarizer.
///
/// - **Stage 1 (per-item)**: fetch my PRs + issues created on/after `fromDate`
///   (via `gh`, reusing `GitHubCLI`), then summarize each *uncached* item to a
///   30–50 字 line with the LLM (`AiTxtClient`) and cache it on disk. Incremental:
///   already-summarized items are skipped.
/// - **Stage 2 (per-month)**: pick one or more months and roll their per-item
///   summaries up into a feature-grouped "what I did" report, also cached.
///
/// Nothing here is GitHub-heavy: `gh` only lists items and pulls each body +
/// commit headlines; both summarizing steps are plain single-shot LLM calls.
@MainActor
@Observable
final class WorkLogViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case failed(String)
    }

    /// Loading state of the cached list (not the summarize/aggregate actions).
    private(set) var phase: Phase = .idle
    /// All cached item summaries, newest first.
    private(set) var items: [WorkItem] = []

    /// Only summarize/aggregate items created on/after this date. Persisted.
    var fromDate: Date {
        didSet { UserDefaults.standard.set(fromDate.timeIntervalSince1970, forKey: Self.fromKey) }
    }

    /// True while Stage 1 (fetch + per-item summarize) is running.
    private(set) var isSummarizing = false
    /// Coarse progress for Stage 1 (summarized-so-far, total-to-summarize).
    private(set) var summarizeProgress: (done: Int, total: Int)?

    /// The period granularity to roll up (quarter / half-year / year).
    var periodKind: PeriodKind = .quarter {
        didSet { if oldValue != periodKind { selectedPeriodKey = nil } }
    }
    /// The `key` of the period bucket picked for a Stage-2 roll-up (e.g. `2026-Q1`).
    var selectedPeriodKey: String?
    /// The most recent aggregate report (rendered Markdown), or empty.
    private(set) var aggregate: String = ""
    private(set) var isAggregating = false

    /// Work-background context injected into the OKR roll-up so the model frames
    /// the summary around my actual role and stack. Editable + persisted.
    var backgroundPrompt: String {
        didSet { UserDefaults.standard.set(backgroundPrompt, forKey: Self.backgroundKey) }
    }

    /// Live filter from the command palette (title / summary substring).
    var searchFilter: String = ""

    private let provider = WorkLogProvider()
    private let store = WorkLogStore()

    private static let fromKey = "houmao.worklog.from"
    private static let backgroundKey = "houmao.worklog.background"

    /// The period granularity for a Stage-2 OKR roll-up.
    enum PeriodKind: String, CaseIterable, Identifiable, Hashable {
        case quarter, half, year
        var id: String { rawValue }
        var label: String {
            switch self {
            case .quarter: return "季度"
            case .half: return "半年"
            case .year: return "全年"
            }
        }
    }

    /// One selectable roll-up period (a quarter / half / year present in the cache).
    struct PeriodBucket: Identifiable, Hashable {
        let key: String      // stable id + storage name, e.g. "2026-Q1"
        let label: String    // display, e.g. "2026 年 Q1"
        let months: [String] // member `yyyy-MM` buckets
        var id: String { key }
    }

    private static let defaultBackground = """
    目前在构建公有云平台。技术栈：Kubernetes + KubeVirt + Kube-OVN + CNI chaining（Cilium）+ Ceph。\
    我的角色是公有云网络架构师，同时也负责监控、运维等相关工作。
    """

    init() {
        if let ts = UserDefaults.standard.object(forKey: Self.fromKey) as? Double {
            fromDate = Date(timeIntervalSince1970: ts)
        } else {
            // Default window: the last 3 months.
            fromDate = Calendar.current.date(byAdding: .month, value: -3, to: Date()) ?? Date()
        }
        backgroundPrompt = UserDefaults.standard.string(forKey: Self.backgroundKey) ?? Self.defaultBackground
    }

    // MARK: - Derived

    /// Items after applying the search filter, newest first.
    private var filteredItems: [WorkItem] {
        let q = searchFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return items }
        return items.filter {
            $0.title.lowercased().contains(q) || $0.summary.lowercased().contains(q)
        }
    }

    /// Month buckets (`yyyy-MM`) present in the (filtered) cache, newest first.
    var months: [String] {
        Array(Set(filteredItems.map(\.monthKey))).sorted(by: >)
    }

    /// The (filtered) items in `month`, newest first.
    func items(in month: String) -> [WorkItem] {
        filteredItems.filter { $0.monthKey == month }.sorted { $0.createdAt > $1.createdAt }
    }

    /// Whether a month should be expanded by default: only the most recent three
    /// calendar months (older buckets fold to keep the panel short).
    func isRecent(_ month: String) -> Bool {
        guard let cutoff = Calendar.current.date(byAdding: .month, value: -3, to: Date()) else { return true }
        return month >= WorkItem.monthKey(cutoff)
    }

    /// All month buckets present in the cache (ignores the search filter), used
    /// to build the roll-up period buckets.
    private var allMonths: [String] { Array(Set(items.map(\.monthKey))) }

    /// Period buckets available from the cache for the current `periodKind`,
    /// newest first.
    var periods: [PeriodBucket] {
        var byKey: [String: (label: String, months: [String])] = [:]
        for month in allMonths {
            guard let b = Self.bucket(for: month, kind: periodKind) else { continue }
            byKey[b.key, default: (b.label, [])].months.append(month)
        }
        return byKey
            .map { PeriodBucket(key: $0.key, label: $0.value.label, months: $0.value.months.sorted()) }
            .sorted { $0.key > $1.key }
    }

    /// The currently selected period bucket, if any.
    var selectedPeriod: PeriodBucket? {
        guard let key = selectedPeriodKey else { return nil }
        return periods.first { $0.key == key }
    }

    /// Toggle a period bucket (single-select: picking the same one clears it).
    func selectPeriod(_ key: String) {
        selectedPeriodKey = (selectedPeriodKey == key) ? nil : key
    }

    /// Map a `yyyy-MM` month to its period bucket key + display label.
    static func bucket(for month: String, kind: PeriodKind) -> (key: String, label: String)? {
        let parts = month.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]),
              let m = Int(parts[1]), (1...12).contains(m) else { return nil }
        switch kind {
        case .quarter:
            let q = (m - 1) / 3 + 1
            return ("\(year)-Q\(q)", "\(year) 年 Q\(q)")
        case .half:
            let h = m <= 6 ? 1 : 2
            return ("\(year)-H\(h)", "\(year) 年\(h == 1 ? "上" : "下")半年")
        case .year:
            return ("\(year)", "\(year) 年")
        }
    }

    // MARK: - Load (cache only)

    /// Load the on-disk cache into `items` (no network). Called on panel open.
    func reload() {
        phase = .loading
        items = store.loadAll().sorted { $0.createdAt > $1.createdAt }
        phase = .idle
    }

    // MARK: - Stage 1: fetch + per-item summarize

    /// Fetch my PRs + issues since `fromDate` and summarize the ones not yet
    /// cached. Incremental and interruption-safe: each summary is saved as soon
    /// as it's produced, so re-running only fills the gaps.
    func generate() async {
        guard !isSummarizing else { return }
        guard let resolved = AppSettings.shared.resolveModel(named: nil) else {
            phase = .failed("未配置模型：请在设置里添加一个 Provider")
            return
        }
        let client = AiTxtClient(
            baseURL: resolved.provider.apiHost, model: resolved.model, apiKey: resolved.provider.apiKey
        )

        isSummarizing = true
        summarizeProgress = nil
        defer { isSummarizing = false; summarizeProgress = nil }

        // 1. List candidate refs (PRs + issues), oldest first.
        let refs: [(ref: WorkItemRef, kind: WorkKind)]
        do {
            async let prs = provider.fetchPRs(since: fromDate)
            async let issues = provider.fetchIssues(since: fromDate)
            let prRefs = try await prs.map { (ref: $0, kind: WorkKind.pr) }
            let issueRefs = try await issues.map { (ref: $0, kind: WorkKind.issue) }
            refs = (prRefs + issueRefs).sorted { $0.ref.createdAt < $1.ref.createdAt }
        } catch {
            phase = .failed(error.localizedDescription)
            return
        }

        // 2. Skip anything already summarized. Identity is the item's URL
        //    (globally unique and stable), so a PR / issue is only ever analyzed
        //    once — no matter when we re-run or how the cache is bucketed.
        let cachedURLs = Set(store.loadAll().map(\.url))
        let pending = refs.filter { !cachedURLs.contains($0.ref.url) }
        summarizeProgress = (0, pending.count)

        for (i, entry) in pending.enumerated() {
            do {
                let context = try await provider.fetchContext(entry.ref, kind: entry.kind)
                let summary = try await client.ask(
                    question: Self.itemPrompt(entry.ref, kind: entry.kind, context: context),
                    attachments: []
                )
                let item = WorkItem(
                    kind: entry.kind, number: entry.ref.number, repoSlug: entry.ref.repoSlug,
                    title: entry.ref.title, url: entry.ref.url, createdAt: entry.ref.createdAt,
                    summary: Self.clean(summary)
                )
                try store.save(item)
            } catch {
                // Best-effort: skip a failed item, keep going. A later re-run
                // retries it (it stays uncached).
            }
            summarizeProgress = (i + 1, pending.count)
        }

        reload()
    }

    // MARK: - Stage 2: per-month aggregate

    /// Roll the per-item summaries of the selected months up into one
    /// feature-grouped report, and cache it.
    func runAggregate() async {
        guard !isAggregating, let period = selectedPeriod else { return }
        guard let resolved = AppSettings.shared.resolveModel(named: nil) else {
            aggregate = "未配置模型：请在设置里添加一个 Provider"
            return
        }
        let client = AiTxtClient(
            baseURL: resolved.provider.apiHost, model: resolved.model, apiKey: resolved.provider.apiKey
        )

        isAggregating = true
        defer { isAggregating = false }

        let picked = items
            .filter { period.months.contains($0.monthKey) }
            .sorted { $0.createdAt < $1.createdAt }
        guard !picked.isEmpty else { aggregate = "这个周期内没有已总结的条目"; return }

        do {
            let report = try await client.ask(
                question: Self.aggregatePrompt(picked, period: period, background: backgroundPrompt),
                attachments: []
            )
            let text = Self.clean(report)
            aggregate = text
            try? store.saveAggregate(name: period.key, markdown: text)
        } catch {
            aggregate = "总结失败：\(error.localizedDescription)"
        }
    }

    // MARK: - Prompts

    private static func itemPrompt(_ ref: WorkItemRef, kind: WorkKind, context: String) -> String {
        """
        用一句话、30–50 个汉字，概括我这个 GitHub \(kind.label) 做了什么（做了哪些改动/解决了什么问题）。\
        只输出这句话本身，不要前缀、不要引号、不要 Markdown。

        标题：\(ref.title)
        仓库：\(ref.repoSlug)

        \(context)
        """
    }

    private static func aggregatePrompt(_ items: [WorkItem], period: PeriodBucket, background: String) -> String {
        let lines = items.map { "- [\($0.monthKey)] \($0.repoSlug) \($0.kind.label) #\($0.number)：\($0.summary)" }
            .joined(separator: "\n")
        let bg = background.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        你是我的工作总结助手。请基于我的工作背景，用 OKR 方法论对我在【\(period.label)】期间**已完成的工作**做一次回顾性总结。

        【我的工作背景】
        \(bg.isEmpty ? "（未提供）" : bg)

        【OKR 方法论要点】
        - Objective（目标）：方向性、有价值的成果方向，回答"这段时间我把哪件事推进到了什么程度"，而不是任务名或模块名；提炼 2–4 个。
        - Key Result（关键成果）：衡量该目标达成度的**结果与影响**，尽量量化（数量 / 覆盖范围 / 性能与稳定性变化 / 完成或推进程度）；\
        确实无法量化时，用"交付了什么能力、达到什么状态"描述，**不要退化成一条条任务的流水账**。每个目标下 2–4 条 KR。
        - 把多条相关的工作聚合进同一条 KR，并在其下引用支撑它的具体 PR / issue 编号。

        【要求】
        - 无论 PR / issue 是否已合并 / 关闭，都是实实在在的工作量，一律纳入总结；不要因为未合并 / 未关闭就省略或弱化，也不要据此评判工作价值高低。
        - 所有目标与 KR 必须从下面的实际工作归纳，**不得凭空编造目标或数字**；摘要里没有的量化指标不要臆造。
        - 结合我的角色（公有云网络架构 / 监控 / 运维）判断每项工作归属哪个方向，同一方向的零散工作合并成一个目标。
        - 突出成果与影响，不要逐条复述每个 PR / issue。
        - 用简洁的中文 Markdown（保留技术名词与标识符英文），结构如下：
          1. 开头一行"概述：…"，一两句点出这段时间的重点。
          2. 每个目标一节：`## Objective N：<目标>`。
          3. 目标下用 `- **KRn**：<可衡量的结果 / 影响>`；每条 KR 再缩进一行 `  - 支撑：<repo> #<num>… — <成果>` 引用来源。

        【这段时间的 PR / issue 逐条摘要】
        \(lines)
        """
    }

    /// Trim the model's answer to a single tidy block (drop stray quotes/blank
    /// edges); the per-item prompt already asks for no wrapping.
    private static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
    }
}
