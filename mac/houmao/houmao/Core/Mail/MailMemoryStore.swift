import Foundation

/// Cross-session memory for the `/mail` workflow (see docs/proactive-agency.md
/// §8):
/// - `summaries`: cached one-line cluster summaries (keyed by exact signature),
///   pre-warmed by `MailWatcher` so opening `/mail` shows them instantly.
/// - `important`: signatures the LLM judged to be a "重点" (needs attention), so
///   `/mail` can surface those first and collapse routine mail.
///
/// **Written by `MailWatcher`, read-only for `MailViewModel`** — opening `/mail`
/// never writes state (no "seen"/read side effect). One JSON file under
/// `~/Documents/houmao/mail/`; the codec is pure for unit testing.
struct MailMemoryStore {
    struct State: Codable, Equatable {
        var summaries: [String: String]
        var important: Set<String>

        static let empty = State(summaries: [:], important: [])
    }

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/houmao/mail", isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("memory.json") }

    func load() -> State {
        guard let data = try? Data(contentsOf: fileURL) else { return .empty }
        return (try? Self.decode(data)) ?? .empty
    }

    func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encode(state).write(to: fileURL, options: .atomic)
    }

    // MARK: - Pure codec (unit-testable)

    static func encode(_ state: State) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(state)
    }

    static func decode(_ data: Data) throws -> State {
        try JSONDecoder().decode(State.self, from: data)
    }
}
