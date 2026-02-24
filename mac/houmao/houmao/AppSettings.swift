import Foundation
import Observation

/// A named LLM worker with an OpenAI-compatible base URL.
struct Worker: Codable, Identifiable, Equatable {
    static let defaultModel = "minicpm-o-4.5"

    let id: UUID
    var name: String
    var url: String
    var model: String

    init(id: UUID = UUID(), name: String, url: String, model: String = Worker.defaultModel) {
        self.id = id
        self.name = name
        self.url = url
        self.model = model
    }
}

/// Worker list stored in UserDefaults.
/// Boolean prefs (showTimestamp, showAppSwitch) live in @AppStorage at the view layer.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var workers: [Worker] {
        didSet { saveWorkers() }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "workers"),
           let decoded = try? JSONDecoder().decode([Worker].self, from: data) {
            self.workers = decoded
        } else {
            self.workers = []
        }
    }

    private func saveWorkers() {
        if let data = try? JSONEncoder().encode(workers) {
            UserDefaults.standard.set(data, forKey: "workers")
        }
    }

    /// Get worker by name, or default worker if name is nil
    func worker(named name: String?) -> Worker? {
        workers.first {
            name == nil ? $0.name.isEmpty : $0.name.caseInsensitiveCompare(name!) == .orderedSame
        }
    }
}
