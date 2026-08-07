import Foundation

/// An async tool execution (§7 document-mediated protocol): a unit of work that
/// produces a result document. `JobStore` (Shell) tracks these so "是否结束" has
/// a single source; completion fires a unified event that resumes the agent.
struct AgentJob: Sendable, Equatable, Identifiable {
    enum Status: String, Sendable, Equatable { case running, succeeded, failed }

    let id: String
    /// pr / issue / mail / triage / … — used for the results/<kind>/ folder.
    let kind: String
    /// Human-facing label for the job (shown while it runs).
    let title: String
    /// Where the result document will be written.
    let documentPath: String
    var status: Status
    var error: String?

    init(id: String, kind: String, title: String, documentPath: String, status: Status = .running, error: String? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.documentPath = documentPath
        self.status = status
        self.error = error
    }
}

/// Filesystem convention for §7 result documents:
/// `~/Documents/houmao/agent/results/<kind>/<id>.md`.
enum AgentResults {
    static func resultsRoot() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/houmao/agent/results", isDirectory: true)
    }

    static func documentURL(kind: String, id: String, root: URL? = nil) -> URL {
        (root ?? resultsRoot())
            .appendingPathComponent(kind, isDirectory: true)
            .appendingPathComponent(sanitize(id) + ".md")
    }

    static func write(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    /// Keep ids filesystem-safe (letters/digits/`-_.`), replacing the rest with `-`.
    private static func sanitize(_ s: String) -> String {
        String(s.map { ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") ? $0 : "-" })
    }
}
