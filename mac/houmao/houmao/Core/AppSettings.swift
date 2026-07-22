import Foundation
import Observation

/// An LLM provider with an OpenAI-compatible endpoint and one or more models.
struct Provider: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String        // Display name, e.g. "OpenAI", "Local"
    var apiHost: String     // Base URL
    var apiKey: String      // Loaded from Keychain at runtime; NOT persisted to UserDefaults
    var models: [String]    // Available model IDs, e.g. ["gpt-4o", "gpt-4o-mini"]
    var contextTokens: Int  // Detected context window (tokens); 0 = unknown

    enum CodingKeys: String, CodingKey {
        case id, name, apiHost, apiKey, models, contextTokens
    }

    init(id: UUID = UUID(), name: String, apiHost: String, apiKey: String = "", models: [String], contextTokens: Int = 0) {
        self.id = id
        self.name = name
        self.apiHost = Provider.cleanURL(apiHost)
        self.apiKey = apiKey
        self.models = models
        self.contextTokens = contextTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.apiHost = Provider.cleanURL(try c.decode(String.self, forKey: .apiHost))
        // `apiKey` only appears in legacy payloads; decode it so it can be
        // migrated into the Keychain, then it is no longer encoded.
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.models = try c.decode([String].self, forKey: .models)
        self.contextTokens = try c.decodeIfPresent(Int.self, forKey: .contextTokens) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(apiHost, forKey: .apiHost)
        // apiKey intentionally omitted — secrets live in the Keychain.
        try c.encode(models, forKey: .models)
        try c.encode(contextTokens, forKey: .contextTokens)
    }

    /// Strip /v1, /v1/chat/completions suffixes users often paste by mistake.
    static func cleanURL(_ raw: String) -> String {
        // A URL contains no whitespace. Keep only the first whitespace-delimited
        // token so pasted values with embedded newlines or duplicated lines
        // (e.g. "https://host/api\nhttps://host/api") don't produce a malformed URL.
        var url = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        for suffix in ["/v1/chat/completions/", "/v1/chat/completions", "/v1/", "/v1"] {
            if url.hasSuffix(suffix) {
                url = String(url.dropLast(suffix.count))
                break
            }
        }
        return url
    }
}

/// Resolved model reference for a query.
struct ResolvedModel {
    let provider: Provider
    let model: String
}

/// Provider list stored in UserDefaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var providers: [Provider] {
        didSet { saveProviders() }
    }

    /// True while `loadAPIKeys()` hydrates `apiKey`s from the Keychain, so the
    /// `providers` `didSet` skips re-persisting (avoids a redundant Keychain
    /// rewrite — and its extra authorization prompt — on every launch).
    @ObservationIgnored private var isHydrating = false

    /// Root directory under which local clones live, used to auto-locate a repo
    /// for `/issue` (so the URL alone is enough). Persisted to UserDefaults.
    var reposRoot: String {
        didSet { UserDefaults.standard.set(reposRoot, forKey: "reposRoot") }
    }

    /// Google OAuth Desktop-app Client ID for the `/mail` (Gmail) workflow and
    /// future Drive integration. Persisted to UserDefaults (not a secret).
    var googleClientID: String {
        didSet { UserDefaults.standard.set(googleClientID, forKey: "googleClientID") }
    }

    /// Google OAuth Desktop-app client secret (not confidential for installed
    /// apps; Google requires it at token exchange alongside PKCE).
    var googleClientSecret: String {
        didSet { UserDefaults.standard.set(googleClientSecret, forKey: "googleClientSecret") }
    }

    /// User custom mail-tag rules, one `名称: 关键词` per line. Parsed lazily via
    /// `mailTags`; matching emails form their own group in `/mail`.
    var mailTagRules: String {
        didSet { UserDefaults.standard.set(mailTagRules, forKey: "mailTagRules") }
    }

    /// Parsed custom tag rules.
    var mailTags: [MailTag] { MailTag.parse(mailTagRules) }

    // MARK: - Proactive agent (主观能动性)

    /// Master switch for the background watcher loop (`AgentDaemon`). Off by
    /// default — the user opts in.
    var agentEnabled: Bool {
        didSet { UserDefaults.standard.set(agentEnabled, forKey: "agentEnabled") }
    }

    /// Poll cadence in minutes.
    var agentIntervalMinutes: Int {
        didSet { UserDefaults.standard.set(agentIntervalMinutes, forKey: "agentIntervalMinutes") }
    }

    /// Quiet-hours window (local hours 0–23); `start == end` disables it.
    var agentQuietStartHour: Int {
        didSet { UserDefaults.standard.set(agentQuietStartHour, forKey: "agentQuietStartHour") }
    }
    var agentQuietEndHour: Int {
        didSet { UserDefaults.standard.set(agentQuietEndHour, forKey: "agentQuietEndHour") }
    }

    /// Per-watcher enable: GitHub (issues assigned to me + PRs requesting my
    /// review).
    var agentGitHubWatcherEnabled: Bool {
        didSet { UserDefaults.standard.set(agentGitHubWatcherEnabled, forKey: "agentGitHubWatcherEnabled") }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "providers"),
           let decoded = try? JSONDecoder().decode([Provider].self, from: data) {
            self.providers = decoded
        } else {
            self.providers = []
        }
        self.reposRoot = UserDefaults.standard.string(forKey: "reposRoot") ?? ""
        self.googleClientID = UserDefaults.standard.string(forKey: "googleClientID") ?? ""
        self.googleClientSecret = UserDefaults.standard.string(forKey: "googleClientSecret") ?? ""
        self.mailTagRules = UserDefaults.standard.string(forKey: "mailTagRules") ?? ""
        // Clean up legacy keys from previous versions
        UserDefaults.standard.removeObject(forKey: "workers")
        let d = UserDefaults.standard
        self.agentEnabled = d.bool(forKey: "agentEnabled")
        self.agentIntervalMinutes = (d.object(forKey: "agentIntervalMinutes") as? Int) ?? AgentPolicy.default.intervalMinutes
        self.agentQuietStartHour = (d.object(forKey: "agentQuietStartHour") as? Int) ?? AgentPolicy.default.quietStartHour
        self.agentQuietEndHour = (d.object(forKey: "agentQuietEndHour") as? Int) ?? AgentPolicy.default.quietEndHour
        self.agentGitHubWatcherEnabled = (d.object(forKey: "agentGitHubWatcherEnabled") as? Bool) ?? true
        // Hydrate API keys from the Keychain (and migrate legacy plaintext keys).
        loadAPIKeys()
    }

    /// Resolve a local repository path for `owner/repo` under `reposRoot`,
    /// trying `<root>/<repo>` then `<root>/<owner>/<repo>`. Returns nil when
    /// `reposRoot` is unset or no matching directory exists.
    func resolveRepoPath(owner: String, repo: String) -> String? {
        let root = (reposRoot as NSString).expandingTildeInPath
        guard !root.isEmpty else { return nil }
        let fm = FileManager.default
        for candidate in ["\(root)/\(repo)", "\(root)/\(owner)/\(repo)"] {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
        }
        return nil
    }

    /// Fill each provider's `apiKey` from the Keychain. If a provider still
    /// carries a plaintext key (decoded from a legacy UserDefaults payload) and
    /// the Keychain has none, migrate it. Re-persisting afterwards scrubs the
    /// plaintext from UserDefaults because `Provider.encode` omits `apiKey`.
    ///
    /// The in-memory hydration itself must NOT re-persist: rewriting every
    /// Keychain item on each launch triggers a redundant `delete+add` and an
    /// extra authorization prompt. So `saveProviders` is suppressed during
    /// hydration and only run when a real migration happened.
    private func loadAPIKeys() {
        var hydrated = providers
        var didMigrate = false
        for i in hydrated.indices {
            let account = hydrated[i].id.uuidString
            if let stored = KeychainStore.get(account) {
                hydrated[i].apiKey = stored
            } else if !hydrated[i].apiKey.isEmpty {
                KeychainStore.set(hydrated[i].apiKey, for: account)
                didMigrate = true
            }
        }
        // Hydrate in memory without re-persisting (suppresses the `didSet`).
        isHydrating = true
        providers = hydrated
        isHydrating = false
        // Only when a legacy plaintext key was migrated do we persist once, to
        // write the Keychain and scrub the plaintext from UserDefaults.
        if didMigrate { saveProviders() }
    }

    private func saveProviders() {
        guard !isHydrating else { return }
        // Persist secrets to the Keychain first.
        for provider in providers {
            KeychainStore.set(provider.apiKey, for: provider.id.uuidString)
        }
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: "providers")
        }
    }

    /// Remove a provider and delete its Keychain secret to avoid orphans.
    func removeProvider(id: UUID) {
        KeychainStore.delete(id.uuidString)
        providers.removeAll { $0.id == id }
    }

    /// Move a provider to the top (make it default).
    func moveProviderToTop(at index: Int) {
        guard index > 0, index < providers.count else { return }
        let provider = providers.remove(at: index)
        providers.insert(provider, at: 0)
    }

    /// Resolve a model by @mention name.
    /// First tries to match a provider name (alias), then falls back to model ID search.
    /// If mention is nil, returns the first provider's first model (default).
    func resolveModel(named mention: String?) -> ResolvedModel? {
        if let mention {
            // 1. Try provider name match first (alias routing)
            if let provider = providers.first(where: { $0.name.caseInsensitiveCompare(mention) == .orderedSame }),
               let model = provider.models.first {
                return ResolvedModel(provider: provider, model: model)
            }
            // 2. Fall back to model ID match
            for provider in providers {
                if let model = provider.models.first(where: { $0.caseInsensitiveCompare(mention) == .orderedSame }) {
                    return ResolvedModel(provider: provider, model: model)
                }
            }
            return nil
        }
        // Default: first provider's first model
        guard let provider = providers.first, let model = provider.models.first else {
            return nil
        }
        return ResolvedModel(provider: provider, model: model)
    }

    /// Detect a provider's context window (see `probeContextWindow`) and cache
    /// it onto the provider (persisted). Best-effort: returns nil when the
    /// endpoint doesn't expose it (e.g. the official OpenAI API).
    @discardableResult
    func detectContextWindow(for id: UUID) async -> Int? {
        guard let provider = providers.first(where: { $0.id == id }) else { return nil }
        let model = provider.models.first ?? ""
        guard let window = await Self.probeContextWindow(
            apiHost: provider.apiHost, apiKey: provider.apiKey, model: model
        ), window > 0 else { return nil }

        await MainActor.run {
            if let i = self.providers.firstIndex(where: { $0.id == id }) {
                self.providers[i].contextTokens = window
            }
        }
        return window
    }

    /// Best-effort detect the context window for every provider that doesn't yet
    /// have one cached. Called lazily (e.g. when the chat opens) so the ring can
    /// show a value without the user visiting Settings.
    func detectMissingContextWindows() async {
        let ids = providers.filter { $0.contextTokens <= 0 }.map(\.id)
        for id in ids {
            await detectContextWindow(for: id)
        }
    }

    /// GET the models endpoint and read the context window for the given model.
    /// Tries the OpenAI-compatible `/v1/models` first (vLLM `max_model_len` /
    /// others `context_length`), then falls back to LM Studio's native
    /// `/api/v0/models` (preferring the actually loaded window). Best-effort:
    /// returns nil when no endpoint exposes it (e.g. the official OpenAI API).
    static func probeContextWindow(apiHost: String, apiKey: String, model: String) async -> Int? {
        if let w = await probeModelsEndpoint(
            apiHost + "/v1/models", apiKey: apiKey, model: model,
            pick: { $0.max_model_len ?? $0.context_length }
        ) {
            return w
        }
        return await probeModelsEndpoint(
            apiHost + "/api/v0/models", apiKey: apiKey, model: model,
            pick: { $0.loaded_context_length ?? $0.max_context_length }
        )
    }

    private struct ModelsResp: Decodable {
        struct Item: Decodable {
            let id: String?
            let max_model_len: Int?
            let context_length: Int?
            let loaded_context_length: Int?
            let max_context_length: Int?
        }
        let data: [Item]
    }

    /// GET a models-list endpoint and return the window chosen by `pick` for the
    /// requested model (falling back to the first entry that exposes one).
    private static func probeModelsEndpoint(
        _ urlString: String, apiKey: String, model: String,
        pick: (ModelsResp.Item) -> Int?
    ) async -> Int? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        if !apiKey.isEmpty {
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let out = try? JSONDecoder().decode(ModelsResp.self, from: data) else { return nil }

        var fallback: Int?
        for m in out.data {
            guard let w = pick(m), w > 0 else { continue }
            if m.id == model { return w }
            if fallback == nil { fallback = w }
        }
        return fallback
    }

}
