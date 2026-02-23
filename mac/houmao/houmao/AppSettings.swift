import SwiftUI
import Combine

/// A named LLM worker with an OpenAI-compatible base URL.
struct Worker: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var url: String
}

/// App settings stored in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var showTimestamp: Bool {
        didSet {
            UserDefaults.standard.set(showTimestamp, forKey: "showTimestamp")
        }
    }

    @Published var showAppSwitch: Bool {
        didSet {
            UserDefaults.standard.set(showAppSwitch, forKey: "showAppSwitch")
        }
    }

    @Published var workers: [Worker] {
        didSet { saveWorkers() }
    }

    private init() {
        self.showTimestamp = UserDefaults.standard.bool(forKey: "showTimestamp")
        self.showAppSwitch = UserDefaults.standard.bool(forKey: "showAppSwitch")
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

    func addWorker(name: String, url: String) {
        workers.append(Worker(name: name, url: url))
    }

    func removeWorker(id: UUID) {
        workers.removeAll { $0.id == id }
    }

    func updateWorker(id: UUID, name: String, url: String) {
        guard let index = workers.firstIndex(where: { $0.id == id }) else { return }
        workers[index].name = name
        workers[index].url = url
    }

    func worker(named name: String) -> Worker? {
        workers.first { $0.name.lowercased() == name.lowercased() }
    }
}
