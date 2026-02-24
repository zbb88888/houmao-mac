import Foundation
import Observation

/// A named LLM worker with an OpenAI-compatible base URL.
struct Worker: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
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

    func worker(named name: String) -> Worker? {
        workers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
