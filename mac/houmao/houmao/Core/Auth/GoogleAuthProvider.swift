import Foundation

/// Google OAuth 2.0 for **Desktop apps** — Authorization Code + PKCE + loopback
/// redirect (`http://127.0.0.1:<port>`). Shared by Drive (Phase 4) and Gmail
/// (Phase 6); the caller passes the scopes it needs.
///
/// This type owns the token lifecycle only — building the authorization URL,
/// exchanging the code, refreshing, and persisting the refresh token in the
/// Keychain. The interactive step (opening a browser + capturing the redirect
/// via a loopback listener) is platform shell work and is injected as a closure
/// so Core stays pure Foundation.
actor GoogleAuthProvider {

    /// Static Google OAuth scopes we may request.
    enum Scope {
        /// Read + modify labels / move to Trash. Cannot permanently delete.
        static let gmailModify = "https://www.googleapis.com/auth/gmail.modify"
        /// Per-file Drive access: the app can only see / manage files it created
        /// (minimal scope; fits the app-managed mirror model). No broad Drive read.
        static let driveFile = "https://www.googleapis.com/auth/drive.file"

        /// The full set the app requests at connect time. A single shared refresh
        /// token covers every feature (Gmail cleanup + Drive sync), so whichever
        /// entry point runs the consent flow grants both — no per-feature tokens.
        static let appDefault = [gmailModify, driveFile]
    }

    /// Keychain account holding the shared Google refresh token.
    static let keychainAccount = "google.oauth.refresh"

    private static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    private static let tokenEndpoint = "https://oauth2.googleapis.com/token"

    struct Config: Sendable {
        var clientID: String
        /// Desktop-app client secret (not confidential; Google requires it at
        /// token exchange for installed apps alongside PKCE).
        var clientSecret: String? = nil
        /// Loopback redirect, e.g. "http://127.0.0.1:0" (port chosen at runtime).
        var redirectURI: String
        var scopes: [String]
    }

    /// Interactive authorization: given the built auth URL, open a browser and
    /// return the full redirect URL captured by the loopback listener.
    typealias AuthorizeHandler = @Sendable (URL) async throws -> URL

    private let config: Config
    private var accessToken: String?
    private var accessTokenExpiry: Date?

    init(config: Config) {
        self.config = config
    }

    // MARK: - Authorization URL

    /// Build the authorization URL for the PKCE flow.
    func authorizationURL(pkce: PKCE.Pair, state: String) throws -> URL {
        guard var components = URLComponents(string: Self.authEndpoint) else {
            throw MailProviderError.invalidResponse("bad auth endpoint")
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: config.clientID),
            URLQueryItem(name: "redirect_uri", value: config.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        guard let url = components.url else {
            throw MailProviderError.invalidResponse("cannot build auth URL")
        }
        return url
    }

    // MARK: - Interactive connect

    /// Run the full connect flow: build URL → `authorize` (browser + loopback)
    /// → parse the `code` → exchange for tokens → persist the refresh token.
    func connect(authorize: AuthorizeHandler) async throws {
        let pkce = PKCE.makePair()
        let state = PKCE.base64URL(Data(UUID().uuidString.utf8))
        let url = try authorizationURL(pkce: pkce, state: state)

        let redirect = try await authorize(url)
        let code = try Self.extractCode(from: redirect, expectedState: state)
        try await exchangeCode(code, verifier: pkce.verifier)
    }

    /// Extract and validate the authorization `code` from the redirect URL.
    static func extractCode(from redirect: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: redirect, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw MailProviderError.requestFailed("授权失败: \(error)")
        }
        guard items.first(where: { $0.name == "state" })?.value == expectedState else {
            throw MailProviderError.invalidResponse("state 不匹配（可能的 CSRF）")
        }
        guard let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw MailProviderError.invalidResponse("回调缺少授权码")
        }
        return code
    }

    // MARK: - Token exchange & refresh

    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
        let refresh_token: String?
    }

    private func exchangeCode(_ code: String, verifier: String) async throws {
        var params = [
            "client_id": config.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": config.redirectURI,
        ]
        if let secret = config.clientSecret { params["client_secret"] = secret }

        let token = try await postToken(params)
        applyAccessToken(token)
        if let refresh = token.refresh_token, !refresh.isEmpty {
            KeychainStore.set(refresh, for: Self.keychainAccount)
        }
    }

    /// Return a valid access token, refreshing if the cached one is expired.
    func validAccessToken() async throws -> String {
        if let token = accessToken, let expiry = accessTokenExpiry, expiry > Date().addingTimeInterval(30) {
            return token
        }
        guard let refresh = KeychainStore.get(Self.keychainAccount), !refresh.isEmpty else {
            throw MailProviderError.notAuthenticated
        }
        var params = [
            "client_id": config.clientID,
            "refresh_token": refresh,
            "grant_type": "refresh_token",
        ]
        if let secret = config.clientSecret { params["client_secret"] = secret }

        do {
            let token = try await postToken(params)
            applyAccessToken(token)
            return token.access_token
        } catch let error as MailProviderError {
            // A revoked or expired refresh token comes back as HTTP 400
            // `invalid_grant`. That token is permanently dead — purge it (and any
            // cached access token) so the app stops retrying a credential Google
            // will never accept and instead falls back to a fresh OAuth flow.
            if case .requestFailed(let body) = error, body.contains("invalid_grant") {
                KeychainStore.delete(Self.keychainAccount)
                accessToken = nil
                accessTokenExpiry = nil
                throw MailProviderError.notAuthenticated
            }
            throw error
        }
    }

    // MARK: - Helpers

    private func applyAccessToken(_ token: TokenResponse) {
        accessToken = token.access_token
        accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expires_in))
    }

    private func postToken(_ params: [String: String]) async throws -> TokenResponse {
        guard let url = URL(string: Self.tokenEndpoint) else {
            throw MailProviderError.invalidResponse("bad token endpoint")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncoded(params).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MailProviderError.invalidResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw MailProviderError.requestFailed("token 请求失败 (\(http.statusCode)): \(body)")
        }
        do {
            return try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw MailProviderError.invalidResponse("token 响应解析失败")
        }
    }

    /// Form-encode parameters (application/x-www-form-urlencoded).
    static func formURLEncoded(_ params: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return params
            .map { key, value in
                let k = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let v = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(k)=\(v)"
            }
            .joined(separator: "&")
    }
}
