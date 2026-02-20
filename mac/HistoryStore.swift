import Foundation

struct UsageRecord: Codable, Identifiable {
    let id: UUID
    let timestamp: Date
    let appName: String
    let text: String
}

final class HistoryStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "houmao.history.store")

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("houmao-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("usage-history.json")
    }

    func loadAll() -> [UsageRecord] {
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([UsageRecord].self, from: data)
        } catch {
            print("Failed to load history: \(error)")
            return []
        }
    }

    func saveAll(_ records: [UsageRecord]) {
        queue.async {
            do {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                let data = try encoder.encode(records)
                try data.write(to: self.fileURL, options: .atomic)
            } catch {
                print("Failed to save history: \(error)")
            }
        }
    }

    func clearAll() {
        saveAll([])
    }
}

