import Foundation

/// Runs the external `ghia` (GitHub Issue Analyzer) binary as a subprocess and
/// returns its Markdown analysis.
///
/// A GUI app inherits a minimal `PATH` and none of the shell's environment, so
/// we (1) augment `PATH` for the Homebrew locations `ghia` needs to find its own
/// `gh` / `rg` dependencies, and (2) pass the LLM provider config explicitly via
/// `OPENAI_*` so `ghia` reuses houmao's configured provider.
struct IssueAnalyzer {
    struct Config {
        var binaryPath: String
        var apiKey: String
        var baseURL: String // OpenAI-compatible base, including the `/v1` suffix.
        var model: String
        var contextTokens: Int // Detected provider context window; 0 = unknown.
    }

    enum AnalyzerError: LocalizedError {
        case binaryNotFound(String)
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let path):
                return "找不到 ghia 可执行文件：\(path)。请先在 client-tools 里 `make build`。"
            case .failed(let message):
                return message
            }
        }
    }

    let config: Config

    /// Default install location of the `ghia` binary (client-tools `make build`).
    static var defaultBinaryPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("houmao/client-tools/bin/ghia")
    }

    /// A streamed event from `ghia`: fine-grained progress (from stderr) or a
    /// chunk of the analysis summary (from stdout).
    enum Event: Sendable {
        case progress(String)
        case content(String)
    }

    /// Stream the analysis of an issue/PR URL against a local repository. `ghia`
    /// prints its summary token-by-token on stdout (→ `.content`) and phase
    /// progress on stderr as `::progress::…` lines (→ `.progress`). `mode` is
    /// `issue` or `pr` (the latter also reviews the diff).
    func stream(url: String, repoPath: String, mode: String) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            guard FileManager.default.isExecutableFile(atPath: config.binaryPath) else {
                continuation.finish(throwing: AnalyzerError.binaryNotFound(config.binaryPath))
                return
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: config.binaryPath)
            process.arguments = ["-url", url, "-repo", repoPath, "-mode", mode, "-timeout", "480s"]

            var env = ProcessInfo.processInfo.environment
            let brewPaths = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
            env["PATH"] = env["PATH"].map { "\(brewPaths):\($0)" } ?? brewPaths
            env["OPENAI_API_KEY"] = config.apiKey
            env["OPENAI_BASE_URL"] = config.baseURL
            env["OPENAI_MODEL"] = config.model
            if config.contextTokens > 0 {
                env["OPENAI_CONTEXT_TOKENS"] = String(config.contextTokens)
            }
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            // Cancelling the consuming task (window close / renew / a new command)
            // terminates the ghia subprocess so it stops burning compute.
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try process.run()
                } catch {
                    continuation.finish(throwing: error)
                    return
                }

                // Read stderr incrementally on its own queue: `::progress::` lines
                // are surfaced as progress events, anything else is error text.
                let errSink = ErrorSink()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let handle = errPipe.fileHandleForReading
                    var buffer = ""
                    func flush(_ line: String) {
                        if line.hasPrefix("::progress::") {
                            continuation.yield(.progress(String(line.dropFirst("::progress::".count))))
                        } else if !line.isEmpty {
                            errSink.append(line + "\n")
                        }
                    }
                    while true {
                        let data = handle.availableData
                        if data.isEmpty { break }
                        buffer += String(data: data, encoding: .utf8) ?? ""
                        while let nl = buffer.firstIndex(of: "\n") {
                            flush(String(buffer[..<nl]))
                            buffer = String(buffer[buffer.index(after: nl)...])
                        }
                    }
                    if !buffer.isEmpty { flush(buffer) }
                    group.leave()
                }

                // Stream stdout content as ghia emits tokens.
                let outHandle = outPipe.fileHandleForReading
                while true {
                    let data = outHandle.availableData
                    if data.isEmpty { break } // EOF
                    if let s = String(data: data, encoding: .utf8), !s.isEmpty {
                        continuation.yield(.content(s))
                    }
                }
                process.waitUntilExit()
                group.wait()

                if process.terminationStatus != 0 && process.terminationReason == .exit {
                    let msg = errSink.value.trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.finish(throwing: AnalyzerError.failed("ghia 退出码 \(process.terminationStatus)：\(msg)"))
                } else {
                    continuation.finish()
                }
            }
        }
    }
}

/// Thread-safe accumulator for subprocess stderr error text.
private final class ErrorSink: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""
    func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    var value: String { lock.lock(); defer { lock.unlock() }; return text }
}
