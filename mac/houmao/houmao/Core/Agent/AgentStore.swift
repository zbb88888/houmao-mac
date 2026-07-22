import Foundation

/// On-disk persistence for the proactive agent: the inbox of surfaced events
/// plus the set of ids already seen (so restarts don't re-notify). Stored as a
/// single JSON file under `~/Documents/houmao/agent/`. Encoding/decoding is pure
/// (static) so it can be unit-tested without touching the filesystem.
struct AgentStore {
    struct State: Codable, Equatable {
        /// The current inbox (surfaced, not-yet-dismissed events).
        var events: [AgentEvent]
        /// Every id ever surfaced (including dismissed ones), for de-duplication.
        var seen: [String]

        static let empty = State(events: [], seen: [])
    }

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/houmao/agent", isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("inbox.json") }

    /// Load persisted state, or `.empty` when the file is missing/corrupt.
    func load() -> State {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        return (try? Self.decode(data)) ?? .empty
    }

    /// Atomically write the state, creating the directory as needed.
    func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(state).write(to: fileURL, options: .atomic)
    }

    // MARK: - Pure codec (unit-testable)

    static func encode(_ state: State) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(state)
    }

    static func decode(_ data: Data) throws -> State {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(State.self, from: data)
    }
}
