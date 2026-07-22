import Foundation

/// Cross-session memory for the `/mail` workflow (see docs/proactive-agency.md
/// §8):
/// - `summaries`: cached one-line cluster summaries (keyed by exact signature),
///   pre-warmed by `MailWatcher` so opening `/mail` shows them instantly.
/// - `seenClusters` / `seenFamilies`: signatures already shown to the user, so
///   recurring or already-reviewed mail collapses instead of being re-triaged.
///
/// One JSON file under `~/Documents/houmao/mail/`; the codec is pure (static)
/// for unit testing without the filesystem.
struct MailMemoryStore {
    struct State: Codable, Equatable {
        var summaries: [String: String]
        var seenClusters: Set<String>
        var seenFamilies: Set<String>

        static let empty = State(summaries: [:], seenClusters: [], seenFamilies: [])
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

    /// A cluster counts as "seen" (collapse it) when either its exact batch or
    /// its recurring family has been shown before.
    static func isSeen(_ state: State, clusterSig: String, familyKey: String) -> Bool {
        state.seenClusters.contains(clusterSig) || state.seenFamilies.contains(familyKey)
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
