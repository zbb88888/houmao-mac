import Foundation
import Network

/// Minimal loopback HTTP listener for the OAuth 2.0 Desktop-app redirect
/// (`http://127.0.0.1:<port>`), the flow Google recommends after deprecating OOB.
///
/// Binds an ephemeral port on the loopback interface, serves exactly one request
/// (the browser redirect carrying `?code=...&state=...`), reconstructs the full
/// redirect URL, shows a tiny "you can close this tab" page, then shuts down.
/// macOS shell code (uses Network); kept out of Core.
final class LoopbackAuthReceiver {
    private var listener: NWListener?
    private var port: UInt16 = 0

    private var portContinuation: CheckedContinuation<UInt16, Error>?
    private var redirectContinuation: CheckedContinuation<URL, Error>?
    private var didResolvePort = false

    /// The redirect URI to register in the auth request, valid after `start()`.
    var redirectURI: String { "http://127.0.0.1:\(port)" }

    /// Start listening and return the chosen loopback port.
    func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        // Force the loopback interface with an OS-assigned ephemeral port.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        self.listener = listener

        return try await withCheckedThrowingContinuation { continuation in
            self.portContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    if let raw = listener.port?.rawValue { self.port = raw }
                    self.resolvePort(.success(self.port))
                case .failed(let error):
                    self.resolvePort(.failure(error))
                case .cancelled:
                    self.resolvePort(.failure(MailProviderError.requestFailed("回环监听被取消")))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: .main)
        }
    }

    /// Await the single browser redirect, returning its full URL.
    func waitForRedirect() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.redirectContinuation = continuation
        }
    }

    /// Stop listening (idempotent).
    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                self.resolveRedirect(.failure(error))
                connection.cancel()
                return
            }
            guard let data, let request = String(data: data, encoding: .utf8),
                  let target = Self.requestTarget(from: request) else {
                self.respond(connection, ok: false)
                return
            }

            let url = URL(string: "http://127.0.0.1:\(self.port)\(target)")
            self.respond(connection, ok: url != nil)
            if let url {
                self.resolveRedirect(.success(url))
            } else {
                self.resolveRedirect(.failure(MailProviderError.invalidResponse("无法解析回调 URL")))
            }
        }
    }

    /// Parse the request target ("/path?query") from the HTTP request line.
    static func requestTarget(from request: String) -> String? {
        guard let line = request.split(separator: "\r\n", maxSplits: 1).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private func respond(_ connection: NWConnection, ok: Bool) {
        let title = ok ? "授权成功" : "授权失败"
        let body = ok ? "已连接 Gmail，可关闭此页面返回 houmao。" : "未收到有效的授权回调。"
        let html = """
        <!doctype html><html lang="zh"><head><meta charset="utf-8">\
        <title>\(title)</title></head><body style="font-family:-apple-system,sans-serif;\
        text-align:center;padding-top:80px;color:#333"><h2>\(title)</h2><p>\(body)</p></body></html>
        """
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """
        connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Continuation guards

    private func resolvePort(_ result: Result<UInt16, Error>) {
        guard !didResolvePort, let continuation = portContinuation else { return }
        didResolvePort = true
        portContinuation = nil
        continuation.resume(with: result)
    }

    private func resolveRedirect(_ result: Result<URL, Error>) {
        guard let continuation = redirectContinuation else { return }
        redirectContinuation = nil
        continuation.resume(with: result)
        stop()
    }
}
