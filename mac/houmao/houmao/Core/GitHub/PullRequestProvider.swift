import Foundation

/// Fetches the current user's pull requests via the GitHub CLI (`gh`), run as a
/// subprocess.
///
/// A GUI app inherits a minimal `PATH` and none of the shell's environment, so
/// we (1) locate `gh` in the common Homebrew / system locations and (2) augment
/// `PATH` so `gh` can find its own `git` dependency. Authentication reuses the
/// user's existing `gh auth login` session — no token handling here.
struct PullRequestProvider {
    enum ProviderError: LocalizedError {
        case ghNotFound
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .ghNotFound:
                return "找不到 gh（GitHub CLI）。请先 `brew install gh` 并 `gh auth login`。"
            case .failed(let message):
                return message.isEmpty ? "gh 命令执行失败。" : message
            }
        }
    }

    /// JSON fields requested from `gh search prs`.
    private static let jsonFields = "title,url,repository,state,updatedAt,closedAt,isDraft"

    /// Locate the `gh` binary in the usual Homebrew / system locations (a GUI
    /// app's `PATH` doesn't include them).
    static func locateBinary() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Open PRs authored by the current user, across all repositories, most
    /// recently updated first.
    func fetchOpen(limit: Int = 100) async throws -> [PullRequestItem] {
        try await run(arguments: [
            "search", "prs",
            "--author=@me",
            "--state=open",
            "--sort", "updated",
            "--order", "desc",
            "--limit", String(limit),
            "--json", Self.jsonFields,
        ])
    }

    /// Closed / merged PRs authored by the current user, closed on or after
    /// `since`, most recently updated first.
    func fetchClosed(since: Date, limit: Int = 100) async throws -> [PullRequestItem] {
        let day = Self.dayFormatter.string(from: since)
        return try await run(arguments: [
            "search", "prs",
            "--author=@me",
            "--state=closed",
            "--closed=>=\(day)",
            "--sort", "updated",
            "--order", "desc",
            "--limit", String(limit),
            "--json", Self.jsonFields,
        ])
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func run(arguments: [String]) async throws -> [PullRequestItem] {
        guard let binary = Self.locateBinary() else { throw ProviderError.ghNotFound }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: binary)
                process.arguments = arguments

                var env = ProcessInfo.processInfo.environment
                let brewPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
                env["PATH"] = env["PATH"].map { "\(brewPaths):\($0)" } ?? brewPaths
                process.environment = env

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // gh's JSON output and any error text are both small, so reading
                // to EOF before waiting can't deadlock the pipe buffer.
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()

                if process.terminationStatus != 0 {
                    let msg = (String(data: errData, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: ProviderError.failed(msg))
                    return
                }

                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let items = try decoder.decode([PullRequestItem].self, from: outData)
                    continuation.resume(returning: items)
                } catch {
                    continuation.resume(throwing: ProviderError.failed("解析 gh 输出失败：\(error.localizedDescription)"))
                }
            }
        }
    }
}
