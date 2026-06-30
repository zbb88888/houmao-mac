import Foundation
import os.log

private let convStoreLog = Logger(subsystem: "com.houmao", category: "ConversationStore")

/// JSON-file persistence for chat conversations, mirroring `HistoryStore`'s
/// lightweight "Codable → JSON on disk" approach (no database). Stored under
/// `~/Documents/houmao/conversations.json`.
///
/// Synchronous and small by design: chat history is modest in size and is only
/// written on turn completion / structural changes, so main-thread IO is fine.
struct ConversationStore {
    private let fileURL: URL

    /// - Parameter fileURL: Override the storage location (used by tests). When
    ///   nil, defaults to `~/Documents/houmao/conversations.json`.
    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let dir = docs.appendingPathComponent("houmao", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("conversations.json")
        }
    }

    func load() -> [Conversation] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([Conversation].self, from: data)
        } catch {
            convStoreLog.error("Failed to load conversations: \(error.localizedDescription)")
            return []
        }
    }

    func save(_ conversations: [Conversation]) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(conversations)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            convStoreLog.error("Failed to save conversations: \(error.localizedDescription)")
        }
    }
}
