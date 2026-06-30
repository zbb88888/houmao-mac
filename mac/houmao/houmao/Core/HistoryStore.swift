import Foundation
import os.log

private let storeLog = Logger(subsystem: "com.houmao", category: "HistoryStore")

struct UsageRecord: Codable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let appName: String
    let text: String
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

    /// Load records from cache or disk.
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

    /// Load the most recent records with pagination support.
    /// - Parameters:
    ///   - limit: Maximum number of records to return.
    ///   - offset: Number of records to skip from the end (newest first).
    /// - Returns: Records sorted newest-first, up to `limit` count.
    func loadRecent(limit: Int = 100, offset: Int = 0) -> [UsageRecord] {
        var all = loadFromDisk()
        all.append(contentsOf: pendingWrites)
        // Sort newest first
        all.sort { $0.timestamp > $1.timestamp }
        let start = min(offset, all.count)
        let end = min(start + limit, all.count)
        return Array(all[start..<end])
    }

    /// Total number of records (cached + pending).
    var totalCount: Int {
        return (cachedRecords?.count ?? 0) + pendingWrites.count
    }

    private func saveAll(_ records: [UsageRecord]) -> Bool {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(records)
            try data.write(to: fileURL, options: .atomic)
            cachedRecords = records
            return true
        } catch {
            storeLog.error("Failed to save history: \(error.localizedDescription)")
            return false
        }
    }

    func append(_ record: UsageRecord) {
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
        if saveAll(all) {
            pendingWrites.removeAll()
        } else {
            storeLog.warning("Flush failed, \(self.pendingWrites.count) records kept in pending queue")
        }
    }

    func clearAll() {
        pendingWrites.removeAll()
        cachedRecords = []
        _ = saveAll([])
    }
}
