import Foundation

/// Cross-session memory for the `/mail` workflow (see docs/proactive-agency.md
/// §8):
/// - `summaries`: cached three-sentence cluster summaries (背景 / 目的 / 是否需
///   进一步处理, keyed by exact signature). Pre-warmed by `MailWatcher` and
///   filled on demand by `MailViewModel` when opening `/mail`, so subsequent
///   opens are instant.
///
/// One JSON file under `~/Documents/houmao/mail/`; the codec is pure for unit
/// testing.
struct MailMemoryStore {
    struct State: Codable, Equatable {
        var summaries: [String: String]

        static let empty = State(summaries: [:])
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
