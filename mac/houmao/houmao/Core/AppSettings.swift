import Foundation
import Observation

/// An LLM provider with an OpenAI-compatible endpoint and one or more models.
struct Provider: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String        // Display name, e.g. "OpenAI", "Local"
    var apiHost: String     // Base URL
    var apiKey: String      // Loaded from Keychain at runtime; NOT persisted to UserDefaults
    var models: [String]    // Available model IDs, e.g. ["gpt-4o", "gpt-4o-mini"]

    enum CodingKeys: String, CodingKey {
        case id, name, apiHost, apiKey, models
    }

    init(id: UUID = UUID(), name: String, apiHost: String, apiKey: String = "", models: [String]) {
        self.id = id
        self.name = name
        self.apiHost = Provider.cleanURL(apiHost)
        self.apiKey = apiKey
        self.models = models
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
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(apiHost, forKey: .apiHost)
        // apiKey intentionally omitted — secrets live in the Keychain.
        try c.encode(models, forKey: .models)
    }

    /// Strip /v1, /v1/chat/completions suffixes users often paste by mistake.
    static func cleanURL(_ raw: String) -> String {
        var url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private init() {
        if let data = UserDefaults.standard.data(forKey: "providers"),
           let decoded = try? JSONDecoder().decode([Provider].self, from: data) {
            self.providers = decoded
        } else {
            self.providers = []
        }
        // Clean up legacy keys from previous versions
        UserDefaults.standard.removeObject(forKey: "workers")
        // Hydrate API keys from the Keychain (and migrate legacy plaintext keys).
        loadAPIKeys()
    }

    /// Fill each provider's `apiKey` from the Keychain. If a provider still
    /// carries a plaintext key (decoded from a legacy UserDefaults payload) and
    /// the Keychain has none, migrate it. Re-persisting afterwards scrubs the
    /// plaintext from UserDefaults because `Provider.encode` omits `apiKey`.
    private func loadAPIKeys() {
        var hydrated = providers
        for i in hydrated.indices {
            let account = hydrated[i].id.uuidString
            if let stored = KeychainStore.get(account) {
                hydrated[i].apiKey = stored
            } else if !hydrated[i].apiKey.isEmpty {
                KeychainStore.set(hydrated[i].apiKey, for: account)
            }
        }
        // Assigning triggers `saveProviders`, which writes secrets to the
        // Keychain and rewrites UserDefaults without plaintext keys.
        providers = hydrated
    }

    private func saveProviders() {
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

}
