import Foundation
import Observation

/// An LLM provider with an OpenAI-compatible endpoint and one or more models.
struct Provider: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String        // Display name, e.g. "OpenAI", "Local"
    var apiHost: String     // Base URL
    var apiKey: String      // Optional API key
    var models: [String]    // Available model IDs, e.g. ["gpt-4o", "gpt-4o-mini"]

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
        self.apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        self.models = try c.decode([String].self, forKey: .models)
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
    }

    private func saveProviders() {
        if let data = try? JSONEncoder().encode(providers) {
            UserDefaults.standard.set(data, forKey: "providers")
        }
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
