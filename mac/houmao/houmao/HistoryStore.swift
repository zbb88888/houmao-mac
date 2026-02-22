import Foundation

nonisolated struct UsageRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let appName: String
    let text: String

    init(id: UUID, timestamp: Date, appName: String, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.appName = appName
        self.text = text
    }
}

actor HistoryStore {
    private let fileURL: URL
    private var cachedRecords: [UsageRecord]?
    private var pendingWrites: [UsageRecord] = []
    private var flushTask: Task<Void, Never>?

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("houmao-logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("usage-history.json")
    }

    /// Load persisted records from cache or disk.
    private func loadFromDisk() -> [UsageRecord] {
        if let cached = cachedRecords {
            return cached
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            cachedRecords = []
            return []
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let records = try decoder.decode([UsageRecord].self, from: data)
            cachedRecords = records
            return records
        } catch {
            cachedRecords = []
            return []
        }
    }

    func loadAll() -> [UsageRecord] {
        var all = loadFromDisk()
        all.append(contentsOf: pendingWrites)
        return all
    }

    private func saveAll(_ records: [UsageRecord]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
            cachedRecords = records
        } catch {
        }
    }

    func append(_ record: UsageRecord) {
        // Add to pending queue
        pendingWrites.append(record)

        // Debounce: flush after 2 seconds of inactivity
        flushTask?.cancel()
        flushTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.flushPendingWrites()
        }
    }

    private func flushPendingWrites() {
        guard !pendingWrites.isEmpty else { return }

        let persisted = loadFromDisk()
        let all = persisted + pendingWrites
        pendingWrites.removeAll()
        saveAll(all)
    }

    func clearAll() {
        pendingWrites.removeAll()
        cachedRecords = []
        saveAll([])
    }
}
