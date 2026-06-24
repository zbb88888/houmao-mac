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
        self.apiHost = apiHost
        self.apiKey = apiKey
        self.models = models
    }
}

/// Resolved model reference for a query.
struct ResolvedModel {
    let provider: Provider
    let model: String       // The model ID
    /// Display label: model name or provider:model if needed.
    var displayName: String { model }
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

    /// All model names across all providers (for help page).
    var allModels: [(provider: Provider, model: String, isDefault: Bool)] {
        var result: [(Provider, String, Bool)] = []
        var isFirst = true
        for provider in providers {
            for model in provider.models {
                result.append((provider, model, isFirst))
                isFirst = false
            }
        }
        return result
    }
}
