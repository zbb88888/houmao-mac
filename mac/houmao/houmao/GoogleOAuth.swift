import AppKit

/// Shell-side helper that runs Google's Desktop-app OAuth flow: start a loopback
/// listener, open the consent page in the browser, capture the redirect, and let
/// `GoogleAuthProvider` exchange the code (persisting the shared refresh token).
///
/// Lives in the app shell (not Core) because it needs `NSWorkspace` + the
/// loopback receiver; `GoogleAuthProvider` stays pure by taking the interactive
/// step as a closure. Shared by the Gmail and Drive entry points so the OAuth
/// dance isn't duplicated.
enum GoogleOAuth {
    /// Build a `GoogleAuthProvider` from the app's stored OAuth Client config
    /// (Client ID/secret shared with Gmail). Single source of the config so the
    /// connect flow, Gmail's refresh-only provider, and Drive's client don't each
    /// rebuild it.
    static func makeProvider(
        redirectURI: String,
        scopes: [String] = GoogleAuthProvider.Scope.appDefault
    ) -> GoogleAuthProvider {
        let settings = AppSettings.shared
        return GoogleAuthProvider(config: .init(
            clientID: settings.googleClientID,
            clientSecret: settings.googleClientSecret.isEmpty ? nil : settings.googleClientSecret,
            redirectURI: redirectURI,
            scopes: scopes
        ))
    }

    /// Run the interactive consent flow for `scopes` and return the connected
    /// provider (its refresh token is now in the Keychain). Throws on failure.
    static func connect(scopes: [String] = GoogleAuthProvider.Scope.appDefault) async throws -> GoogleAuthProvider {
        let receiver = LoopbackAuthReceiver()
        _ = try await receiver.start()
        let auth = makeProvider(redirectURI: receiver.redirectURI, scopes: scopes)
        do {
            try await auth.connect { url in
                NSWorkspace.shared.open(url)
                return try await receiver.waitForRedirect()
            }
        } catch {
            receiver.stop()
            throw error
        }
        return auth
    }
}

/// The app's **single shared Google client**: Gmail and Drive both obtain access
/// tokens from the same `GoogleAuthProvider`, so there's one refresh-token
/// lifecycle and one in-memory access-token cache — no duplicate refreshes and
/// no per-request provider churn. The interactive consent runs through
/// `GoogleOAuth.connect`; afterwards the shared provider is rebuilt so it uses
/// the freshly granted token / current Client config.
@MainActor
enum GoogleAccount {
    private static var provider = GoogleOAuth.makeProvider(redirectURI: "http://127.0.0.1:0")

    /// A valid access token, refreshing from the shared refresh token as needed.
    /// The refresh runs on `GoogleAuthProvider`'s actor (off the main thread);
    /// this only awaits it.
    static func accessToken() async throws -> String {
        try await provider.validAccessToken()
    }

    /// Whether a Google session exists (shared refresh token in the Keychain).
    static var isConnected: Bool {
        KeychainStore.get(GoogleAuthProvider.keychainAccount)?.isEmpty == false
    }

    /// Run interactive consent, then rebuild the shared provider so it picks up
    /// the new token / current Client config immediately.
    static func connect() async throws {
        _ = try await GoogleOAuth.connect()
        provider = GoogleOAuth.makeProvider(redirectURI: "http://127.0.0.1:0")
    }
}
