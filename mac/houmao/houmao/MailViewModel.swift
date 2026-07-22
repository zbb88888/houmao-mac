import SwiftUI
import AppKit
import Observation
import os.log

private let mailLog = Logger(subsystem: "com.houmao", category: "Mail")

/// Drives the `/mail` cleanup workflow (Phase 6): connect Gmail (OAuth), list +
/// classify + cluster recent mail, let the user review/select, then move the
/// selection to Trash. AI-free by default (see ADR-9); LLM summaries are a
/// future optional enhancement.
@MainActor
@Observable
final class MailViewModel {
    enum Phase: Equatable {
        case needsConnection
        case connecting
        case loading
        case review
        case failed(String)
    }

    /// A just-completed action the user can still reverse (feedback + 撤销).
    struct UndoAction {
        let label: String
        let perform: () async -> Void
    }

    /// Detail-view state for the double-clicked message. `nil` means no detail
    /// is open (the sheet is dismissed).
    enum DetailState: Equatable {
        case loading
        case loaded(MailMessageDetail)
        case failed(String)
    }

    var phase: Phase
    var clusters: [MailCluster] = []
    var selectedIDs: Set<String> = []
    /// True while a trash / mark-read mutation is in flight (keeps the list
    /// visible with a lightweight busy indicator instead of a full-screen spinner).
    var isMutating = false
    /// The last reversible action, surfaced as a banner with an 撤销 button.
    var undoAction: UndoAction?
    /// Auto-dismisses `undoAction` after a few seconds so the banner doesn't
    /// linger forever; cancelled/replaced whenever a new action is shown.
    private var undoAutoDismiss: Task<Void, Never>?
    /// Content of the double-clicked message (nil → detail sheet hidden).
    var detail: DetailState?
    /// The id the detail request is for, so stale responses can be ignored.
    private var detailMessageID: String?
    /// Last AI analysis (selection key + time), used to ignore accidental
    /// double-clicks that would re-analyze the same selection within seconds.
    private var lastAnalysis: (key: String, at: Date)?
    /// False until the first successful `load()`, so the UI can tell a fresh
    /// (not-yet-loaded) review state from a genuinely empty result.
    private(set) var hasLoaded = false

    /// Gmail `q` filter for the coarse server-side pre-filter. Unread inbox only
    /// — read mail is intentionally skipped (triage focuses on the new stuff).
    var query: String = "is:unread in:inbox newer_than:30d"
    /// Cap on the number of messages pulled per run (keeps O(n²) clustering fast).
    var maxResults: Int = 200

    /// Local, case-insensitive filter over already-loaded mail (subject / sender).
    /// Empty → show everything. Set by the mail page search box; unlike `query`
    /// it never triggers a Gmail refetch — it only narrows what's on screen.
    var searchFilter: String = ""

    /// Raw fetched messages, kept so `regroup()` can re-cluster without refetching.
    private var loadedMessages: [MailMessage] = []

    // MARK: - Proactive mail importance (docs/proactive-agency.md §8)

    private let mailMemory = MailMemoryStore()
    /// Cached one-line summary per cluster (by runtime id), pre-warmed by the
    /// mail watcher — shown inline so the list needs no on-open LLM wait.
    var summaryByCluster: [UUID: String] = [:]
    /// Clusters judged important (「重点」), so they stay visible and are the
    /// only ones shown by default.
    private var importantClusterIDs: Set<UUID> = []
    /// Collapse routine (non-important) mail by default so only 重点 needs a look.
    var hideRoutine = true

    init() {
        // If a refresh token already exists we're effectively connected.
        let connected = KeychainStore.get(GoogleAuthProvider.keychainAccount)?.isEmpty == false
        self.phase = connected ? .review : .needsConnection
    }

    var isConfigured: Bool { !AppSettings.shared.googleClientID.isEmpty }

    /// Whether a Gmail session already exists (refresh token in Keychain), so
    /// opening `/mail` can auto-refresh without prompting a fresh OAuth flow.
    var isConnected: Bool { GoogleAccount.isConnected }

    var selectedCount: Int { selectedIDs.count }

    // MARK: - Connect

    /// Run the OAuth Desktop-app flow (browser + loopback), then load mail.
    func connect() async {
        guard isConfigured else {
            phase = .failed("未配置 Google OAuth Client ID，请在设置（⌘,）中填写后重试。")
            return
        }
        phase = .connecting
        do {
            try await GoogleAccount.connect()
            mailLog.info("OAuth token exchange succeeded; loading mail")
            await load()
        } catch {
            mailLog.error("OAuth connect failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Load

    /// List → fetch metadata → classify + cluster → preselect low-priority.
    func load() async {
        guard let provider = makeProvider() else {
            phase = .needsConnection
            return
        }
        phase = .loading
        dismissUndo()
        do {
            let ids = try await provider.listMessages(query: query, maxResults: maxResults)
            mailLog.info("listMessages returned \(ids.count) ids for query \(self.query, privacy: .public)")
            loadedMessages = try await provider.fetchMetadata(ids: ids)
            applyGrouping()
            hasLoaded = true
            phase = .review
        } catch MailProviderError.notAuthenticated {
            // The stored session is gone — either we never connected, or the
            // refresh token was revoked/expired and `validAccessToken()` just
            // purged it. Auto re-run the OAuth flow so the user recovers in one
            // step instead of hitting a dead-end error with a stale token.
            mailLog.error("load: not authenticated; re-running OAuth")
            if isConfigured {
                await connect()
            } else {
                phase = .needsConnection
            }
        } catch {
            mailLog.error("load failed: \(error.localizedDescription, privacy: .public)")
            phase = .failed(error.localizedDescription)
        }
    }

    /// Re-run grouping over the already-fetched messages (e.g. after the user
    /// edits custom tags) — no network round-trip.
    func regroup() {
        guard hasLoaded else { return }
        applyGrouping()
    }

    private func applyGrouping() {
        let grouped = MailGrouping.group(loadedMessages, customTags: AppSettings.shared.mailTags)
        mailLog.info("grouped \(self.loadedMessages.count) messages into \(grouped.count) clusters")
        clusters = grouped
        applyMailImportance(to: grouped)
        // UX: preselect the first mail so the user can act on it immediately
        // (e.g. hit AI / delete, one at a time) without a manual first click.
        selectFirst()
    }

    /// Attach cached summaries + which clusters are important, from the mail
    /// watcher's memory. **Read-only** — opening `/mail` never writes state, so
    /// there is no "seen"/read side effect. Falls back to the heuristic
    /// `!isRoutine` when the watcher hasn't classified a cluster yet.
    private func applyMailImportance(to grouped: [MailCluster]) {
        let state = mailMemory.load()
        var summaries: [UUID: String] = [:]
        var important: Set<UUID> = []
        for cluster in grouped {
            let sig = MailSignature.cluster(cluster)
            if let cached = state.summaries[sig] { summaries[cluster.id] = cached }
            let classified = state.summaries[sig] != nil
            let isImportant = classified
                ? state.important.contains(sig)
                : !MailImportance.isRoutine(cluster)
            if isImportant { important.insert(cluster.id) }
        }
        summaryByCluster = summaries
        importantClusterIDs = important
    }

    /// The first cluster in display order (first primary → first subgroup →
    /// first cluster), or nil when the list is empty.
    private var firstCluster: MailCluster? {
        groupedClusters.first?.subgroups.first?.clusters.first
    }

    /// Reset the selection to the whole first cluster. Used on a fresh load and
    /// after a batch removal so a full cluster is always ready to act on. The AI
    /// reviews a cluster as one thread, so once reviewed the whole cluster should
    /// clear in a single delete — not one message at a time.
    private func selectFirst() {
        selectedIDs.removeAll()
        guard let cluster = firstCluster else { return }
        for message in cluster.messages { selectedIDs.insert(message.id) }
    }

    // MARK: - Selection

    /// Clusters arranged as a two-level tree — primary (大类) → secondary (小类)
    /// → clusters — preserving `MailGrouping`'s ordering, so the UI renders one
    /// non-collapsing section per primary with sub-headers per secondary.
    var groupedClusters: [(primary: String, subgroups: [(secondary: String?, clusters: [MailCluster])])] {
        var primaryOrder: [String] = []
        var primaryMap: [String: [MailCluster]] = [:]
        for cluster in visibleClusters {
            if primaryMap[cluster.primary] == nil { primaryOrder.append(cluster.primary) }
            primaryMap[cluster.primary, default: []].append(cluster)
        }
        return primaryOrder.map { primary in
            let group = primaryMap[primary] ?? []
            var secondaryOrder: [String?] = []
            var secondaryMap: [String?: [MailCluster]] = [:]
            for cluster in group {
                if secondaryMap[cluster.secondary] == nil { secondaryOrder.append(cluster.secondary) }
                secondaryMap[cluster.secondary, default: []].append(cluster)
            }
            let subgroups = secondaryOrder.map { (secondary: $0, clusters: secondaryMap[$0] ?? []) }
            return (primary: primary, subgroups: subgroups)
        }
    }

    /// `clusters` narrowed by `searchFilter`: a cluster is kept if its
    /// representative subject matches, otherwise it's shrunk to just the messages
    /// whose subject / sender match (so counts and rows reflect the filter).
    private var filteredClusters: [MailCluster] {
        let q = searchFilter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return clusters }
        return clusters.compactMap { cluster in
            if cluster.representativeSubject.lowercased().contains(q) { return cluster }
            let matches = cluster.messages.filter {
                $0.subject.lowercased().contains(q) || $0.from.lowercased().contains(q)
            }
            guard !matches.isEmpty else { return nil }
            return MailCluster(
                id: cluster.id,
                primary: cluster.primary,
                secondary: cluster.secondary,
                category: cluster.category,
                messages: matches
            )
        }
    }

    func isSelected(_ id: String) -> Bool { selectedIDs.contains(id) }

    /// `filteredClusters` with routine (non-important) clusters dropped when
    /// `hideRoutine`, so the list shows only 重点 by default.
    private var visibleClusters: [MailCluster] {
        guard hideRoutine else { return filteredClusters }
        return filteredClusters.filter { importantClusterIDs.contains($0.id) }
    }

    /// How many (search-matching) clusters are routine (non-important) — drives
    /// the collapse banner and its show/hide toggle.
    var routineCount: Int {
        filteredClusters.filter { !importantClusterIDs.contains($0.id) }.count
    }

    /// Whether a cluster is a highlighted 重点 (drives the row badge + ordering).
    func isImportant(_ cluster: MailCluster) -> Bool {
        importantClusterIDs.contains(cluster.id)
    }

    /// Whether *any* of the cluster's messages are selected. Drives the cluster
    /// row's plain checked/unchecked checkbox, so a single auto-selected mail
    /// still shows the (collapsed) cluster as checked — one consistent tick,
    /// never a partial dash.
    func isClusterSelected(_ cluster: MailCluster) -> Bool {
        cluster.messages.contains { selectedIDs.contains($0.id) }
    }

    func toggleMessage(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    func toggleCluster(_ cluster: MailCluster) {
        let ids = cluster.messages.map(\.id)
        if isClusterSelected(cluster) {
            ids.forEach { selectedIDs.remove($0) }
        } else {
            ids.forEach { selectedIDs.insert($0) }
        }
    }

    // MARK: Whole-group (section) selection

    private func messageIDs(in clusters: [MailCluster]) -> [String] {
        clusters.flatMap { $0.messages.map(\.id) }
    }

    func groupCount(_ clusters: [MailCluster]) -> Int { messageIDs(in: clusters).count }

    func isGroupFullySelected(_ clusters: [MailCluster]) -> Bool {
        let ids = messageIDs(in: clusters)
        return !ids.isEmpty && ids.allSatisfy { selectedIDs.contains($0) }
    }

    func toggleGroup(_ clusters: [MailCluster]) {
        let ids = messageIDs(in: clusters)
        if isGroupFullySelected(clusters) {
            ids.forEach { selectedIDs.remove($0) }
        } else {
            ids.forEach { selectedIDs.insert($0) }
        }
    }

    // MARK: - Actions

    /// Move the selected messages to Trash (recoverable). Removes them from the
    /// list in place so triage keeps flowing; offers an undo.
    func submitCleanup() async {
        guard !selectedIDs.isEmpty, let provider = makeProvider() else { return }
        let ids = Array(selectedIDs)
        await mutate(ids: ids, label: "已移入废纸篓 \(ids.count) 封") {
            try await provider.trashMessages(ids: ids)
        } reverse: {
            try await provider.untrash(ids: ids)
        }
    }

    /// Mark the selected messages as read. Since the list shows unread only,
    /// they drop out of view afterwards; offers an undo.
    func markRead() async {
        guard !selectedIDs.isEmpty, let provider = makeProvider() else { return }
        let ids = Array(selectedIDs)
        await mutate(ids: ids, label: "已标记已读 \(ids.count) 封") {
            try await provider.markRead(ids: ids)
        } reverse: {
            try await provider.markUnread(ids: ids)
        }
    }

    func dismissUndo() {
        undoAutoDismiss?.cancel()
        undoAutoDismiss = nil
        undoAction = nil
    }

    /// Show a reversible action banner that auto-hides after 5 seconds.
    private func setUndo(_ action: UndoAction) {
        undoAutoDismiss?.cancel()
        undoAction = action
        undoAutoDismiss = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.undoAction = nil
            self?.undoAutoDismiss = nil
        }
    }

    /// Run a mutation in place: keep the list visible, remove the affected rows,
    /// then expose an undo that reverses the change server-side and reloads.
    /// Returns whether the action succeeded.
    @discardableResult
    private func mutate(
        ids: [String],
        label: String,
        action: @escaping () async throws -> Void,
        reverse: @escaping () async throws -> Void
    ) async -> Bool {
        isMutating = true
        defer { isMutating = false }
        do {
            try await action()
            removeFromView(ids: Set(ids))
            setUndo(UndoAction(label: label) { [weak self] in
                guard let self else { return }
                self.dismissUndo()
                do { try await reverse(); await self.load() }
                catch { self.phase = .failed(error.localizedDescription) }
            })
            return true
        } catch {
            phase = .failed(error.localizedDescription)
            return false
        }
    }

    // MARK: - LLM (optional)

    /// Whether an LLM model is configured (so the "AI 分析" action is available).
    var canAnalyze: Bool { AppSettings.shared.resolveModel(named: nil) != nil }

    // MARK: - Detail view

    /// Fetch and show the full content of a double-clicked message. Ignores a
    /// response if the user has since opened another message or closed the sheet.
    func openDetail(_ message: MailMessage) async {
        guard let provider = makeProvider() else { return }
        detailMessageID = message.id
        detail = .loading
        // Show the standalone detail window immediately (with a spinner) so the
        // click feels responsive while the body is fetched.
        NotificationCenter.default.post(name: .houmaoOpenMailDetail, object: nil)
        do {
            let full = try await provider.fetchFull(id: message.id)
            guard detailMessageID == message.id else { return }
            detail = .loaded(full)
        } catch {
            guard detailMessageID == message.id else { return }
            detail = .failed(error.localizedDescription)
        }
    }

    func closeDetail() {
        detail = nil
        detailMessageID = nil
    }

    /// Move the message shown in the detail window to Trash, then close the
    /// window. Mirrors the list's delete: removes it in place and offers an undo.
    func deleteDetail() async {
        guard let id = detailMessageID, let provider = makeProvider() else { return }
        let ids = [id]
        let ok = await mutate(ids: ids, label: "已移入废纸篓 1 封") {
            try await provider.trashMessages(ids: ids)
        } reverse: {
            try await provider.untrash(ids: ids)
        }
        guard ok else { return }
        closeDetail()
        NotificationCenter.default.post(name: .houmaoCloseMailDetail, object: nil)
    }

    // MARK: - AI analysis (single selected message)

    /// Analyze the selected mail as a task bubble in the chat window. Selecting a
    /// whole cluster analyzes it **as one thread**: the messages are ordered
    /// oldest→newest and sent together so the AI can follow the story over time.
    /// A GitHub PR/issue link runs the `/pr` / `/issue` flow; otherwise a summary.
    /// No window is activated, so the AI button stays usable for the next batch.
    func analyzeSelected() async {
        guard !selectedIDs.isEmpty, let provider = makeProvider() else { return }
        // Ignore an accidental repeat: same selection re-triggered within 5s.
        let key = selectedIDs.sorted().joined(separator: ",")
        if let last = lastAnalysis, last.key == key, Date().timeIntervalSince(last.at) < 5 {
            return
        }
        lastAnalysis = (key: key, at: Date())
        let selected = loadedMessages
            .filter { selectedIDs.contains($0.id) }
            .sorted { $0.date < $1.date }
        guard !selected.isEmpty else { return }
        var mails: [MailMessageDetail] = []
        for message in selected {
            if let full = try? await provider.fetchFull(id: message.id) { mails.append(full) }
        }
        guard !mails.isEmpty else { return }
        let github = mails.lazy.compactMap { Self.firstGitHubURL(in: $0.body) }.first
        AppDelegate.shared?.mainViewModel.analyzeMailForChat(mails: mails, github: github)
    }

    /// First GitHub issue/PR URL in `text`, with its analysis mode
    /// (`pr` for `/pull/`, `issue` for `/issues/`); nil when none is present.
    static func firstGitHubURL(in text: String) -> (url: String, mode: String)? {
        let pattern = #"https?://github\.com/[^/\s]+/[^/\s]+/(pull|issues)/\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let urlRange = Range(match.range, in: text) else { return nil }
        let url = String(text[urlRange])
        return (url, url.contains("/pull/") ? "pr" : "issue")
    }

    // MARK: - Helpers

    private func removeFromView(ids: Set<String>) {
        clusters = clusters.compactMap { cluster in
            let remaining = cluster.messages.filter { !ids.contains($0.id) }
            return remaining.isEmpty ? nil : MailCluster(id: cluster.id, primary: cluster.primary, secondary: cluster.secondary, category: cluster.category, messages: remaining)
        }
        loadedMessages.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
        // After a batch removal, preselect the new first mail so triage keeps
        // flowing without a manual re-click.
        selectFirst()
    }

    /// Build a Gmail provider backed by the shared Google account's token.
    private func makeProvider() -> GmailProvider? {
        guard isConfigured else { return nil }
        return GmailProvider(accessTokenProvider: { try await GoogleAccount.accessToken() })
    }
}
