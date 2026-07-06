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

    var phase: Phase
    var clusters: [MailCluster] = []
    var selectedIDs: Set<String> = []
    /// True while a trash / mark-read mutation is in flight (keeps the list
    /// visible with a lightweight busy indicator instead of a full-screen spinner).
    var isMutating = false
    /// The last reversible action, surfaced as a banner with an 撤销 button.
    var undoAction: UndoAction?
    /// False until the first successful `load()`, so the UI can tell a fresh
    /// (not-yet-loaded) review state from a genuinely empty result.
    private(set) var hasLoaded = false

    /// Optional LLM insight per cluster id (Phase 6.6). Filled progressively by
    /// `analyzeInsights()`; the core workflow works fine without it.
    var insights: [UUID: MailClusterInsight] = [:]
    /// True while `analyzeInsights()` is running.
    var isAnalyzing = false

    /// Gmail `q` filter for the coarse server-side pre-filter. Unread inbox only
    /// — read mail is intentionally skipped (triage focuses on the new stuff).
    var query: String = "is:unread in:inbox newer_than:30d"
    /// Cap on the number of messages pulled per run (keeps O(n²) clustering fast).
    var maxResults: Int = 200

    private var auth: GoogleAuthProvider?
    /// Raw fetched messages, kept so `regroup()` can re-cluster without refetching.
    private var loadedMessages: [MailMessage] = []

    init() {
        // If a refresh token already exists we're effectively connected.
        let connected = KeychainStore.get(GoogleAuthProvider.keychainAccount)?.isEmpty == false
        self.phase = connected ? .review : .needsConnection
    }

    var isConfigured: Bool { !AppSettings.shared.googleClientID.isEmpty }

    var selectedCount: Int { selectedIDs.count }

    // MARK: - Connect

    /// Run the OAuth Desktop-app flow (browser + loopback), then load mail.
    func connect() async {
        guard isConfigured else {
            phase = .failed("未配置 Google OAuth Client ID，请在设置（⌘,）中填写后重试。")
            return
        }
        phase = .connecting
        let receiver = LoopbackAuthReceiver()
        do {
            let port = try await receiver.start()
            mailLog.info("OAuth loopback listening on 127.0.0.1:\(port)")
            let auth = makeAuth(redirectURI: receiver.redirectURI)
            try await auth.connect { url in
                NSWorkspace.shared.open(url)
                return try await receiver.waitForRedirect()
            }
            mailLog.info("OAuth token exchange succeeded; loading mail")
            self.auth = auth
            await load()
        } catch {
            receiver.stop()
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
        undoAction = nil
        do {
            let ids = try await provider.listMessages(query: query, maxResults: maxResults)
            mailLog.info("listMessages returned \(ids.count) ids for query \(self.query, privacy: .public)")
            loadedMessages = try await provider.fetchMetadata(ids: ids)
            applyGrouping()
            hasLoaded = true
            phase = .review
        } catch MailProviderError.notAuthenticated {
            mailLog.error("load: not authenticated")
            phase = .needsConnection
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
        insights = [:]
        // UX: keep the default state fully unselected; users explicitly decide.
        selectedIDs.removeAll()
    }

    // MARK: - Selection

    /// Clusters grouped by display group, preserving `MailGrouping`'s ordering,
    /// so the UI renders one non-collapsing section per group.
    var groupedClusters: [(key: MailGroupKey, clusters: [MailCluster])] {
        var order: [MailGroupKey] = []
        var map: [MailGroupKey: [MailCluster]] = [:]
        for cluster in clusters {
            let key = cluster.groupKey
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(cluster)
        }
        return order.map { ($0, map[$0] ?? []) }
    }

    func isSelected(_ id: String) -> Bool { selectedIDs.contains(id) }

    func isClusterFullySelected(_ cluster: MailCluster) -> Bool {
        !cluster.messages.isEmpty && cluster.messages.allSatisfy { selectedIDs.contains($0.id) }
    }

    func toggleMessage(_ id: String) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    func toggleCluster(_ cluster: MailCluster) {
        let ids = cluster.messages.map(\.id)
        if isClusterFullySelected(cluster) {
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

    func dismissUndo() { undoAction = nil }

    /// Run a mutation in place: keep the list visible, remove the affected rows,
    /// then expose an undo that reverses the change server-side and reloads.
    private func mutate(
        ids: [String],
        label: String,
        action: @escaping () async throws -> Void,
        reverse: @escaping () async throws -> Void
    ) async {
        isMutating = true
        defer { isMutating = false }
        do {
            try await action()
            removeFromView(ids: Set(ids))
            undoAction = UndoAction(label: label) { [weak self] in
                guard let self else { return }
                self.undoAction = nil
                do { try await reverse(); await self.load() }
                catch { self.phase = .failed(error.localizedDescription) }
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - LLM insights (optional, Phase 6.6)

    /// Whether an LLM model is configured (so the "AI 分析" action is available).
    var canAnalyze: Bool { AppSettings.shared.resolveModel(named: nil) != nil }

    /// Best-effort: ask the LLM for a one-line summary + importance per cluster
    /// (one round-trip per cluster, on its representative sample). Fills
    /// `insights` progressively; per-cluster failures are skipped silently.
    func analyzeInsights() async {
        guard !isAnalyzing, let resolved = AppSettings.shared.resolveModel(named: nil) else { return }
        let analyzer = MailInsightAnalyzer(client: AiTxtClient(
            baseURL: resolved.provider.apiHost,
            model: resolved.model,
            apiKey: resolved.provider.apiKey
        ))
        isAnalyzing = true
        defer { isAnalyzing = false }

        for cluster in clusters {
            if insights[cluster.id] != nil { continue }
            if let insight = try? await analyzer.analyze(cluster) {
                insights[cluster.id] = insight
            }
        }
    }

    /// Select every cluster the LLM suggested deleting (additive to the current
    /// selection). No-op until `analyzeInsights()` has produced insights.
    func applyAISuggestions() {
        for cluster in clusters where insights[cluster.id]?.suggestDelete == true {
            cluster.messages.forEach { selectedIDs.insert($0.id) }
        }
    }

    // MARK: - Helpers

    private func removeFromView(ids: Set<String>) {
        clusters = clusters.compactMap { cluster in
            let remaining = cluster.messages.filter { !ids.contains($0.id) }
            return remaining.isEmpty ? nil : MailCluster(id: cluster.id, category: cluster.category, customTag: cluster.customTag, messages: remaining)
        }
        loadedMessages.removeAll { ids.contains($0.id) }
        selectedIDs.subtract(ids)
    }

    private func makeAuth(redirectURI: String) -> GoogleAuthProvider {
        let settings = AppSettings.shared
        return GoogleAuthProvider(config: .init(
            clientID: settings.googleClientID,
            clientSecret: settings.googleClientSecret.isEmpty ? nil : settings.googleClientSecret,
            redirectURI: redirectURI,
            scopes: [GoogleAuthProvider.Scope.gmailModify]
        ))
    }

    /// Build a Gmail provider from the current (or Keychain-backed) auth.
    private func makeProvider() -> GmailProvider? {
        let auth = self.auth ?? {
            // Refresh-only provider for a returning session (redirect unused).
            let a = makeAuth(redirectURI: "http://127.0.0.1:0")
            self.auth = a
            return a
        }()
        guard isConfigured else { return nil }
        return GmailProvider(accessTokenProvider: { try await auth.validAccessToken() })
    }
}
