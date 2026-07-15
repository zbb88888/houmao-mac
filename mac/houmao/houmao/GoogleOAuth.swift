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
