import Foundation

/// Shared helper to run the GitHub CLI (`gh`) as a subprocess and decode its
/// JSON output.
///
/// A GUI app inherits a minimal `PATH` and none of the shell's environment, so
/// we (1) locate `gh` in the common Homebrew / system locations and (2) augment
/// `PATH` so `gh` can find its own `git` dependency. Authentication reuses the
/// user's existing `gh auth login` session — no token handling here.
enum GitHubCLI {
    enum CLIError: LocalizedError {
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

    /// Locate the `gh` binary in the usual Homebrew / system locations (a GUI
    /// app's `PATH` doesn't include them).
    static func locateBinary() -> String? {
        let candidates = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Run `gh <arguments>` and decode its stdout as JSON `T` (ISO-8601 dates).
    /// Throws `CLIError` if `gh` is missing, exits non-zero, or output can't be
    /// decoded.
    static func runJSON<T: Decodable>(_ arguments: [String]) async throws -> T {
        guard let binary = locateBinary() else { throw CLIError.ghNotFound }
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
                    continuation.resume(throwing: CLIError.failed(msg))
                    return
                }

                do {
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    continuation.resume(returning: try decoder.decode(T.self, from: outData))
                } catch {
                    continuation.resume(throwing: CLIError.failed("解析 gh 输出失败：\(error.localizedDescription)"))
                }
            }
        }
    }
}
