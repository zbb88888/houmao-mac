import Foundation
import os.log

private let convStoreLog = Logger(subsystem: "com.houmao", category: "ConversationStore")

/// Persistence for chat conversations. By default the chat is **ephemeral**
/// (in-memory only, not cached to disk). A persistent location can be opted into
/// (e.g. /tmp/houmao/chat for temporary caching, or a test fixture file).
struct ConversationStore {
    /// nil ⇒ ephemeral (no disk IO).
    private let fileURL: URL?

    /// Ephemeral store: chat history is not cached.
    init() {
        self.fileURL = nil
    }

    /// Persistent store backed by `fileURL` (tests / opt-in caching).
    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func load() -> [Conversation] {
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
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
        guard let fileURL else { return } // ephemeral: nothing to persist
        do {
            let dir = fileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(conversations)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            convStoreLog.error("Failed to save conversations: \(error.localizedDescription)")
        }
    }
}
