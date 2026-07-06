import Foundation
import CryptoKit

/// PKCE (RFC 7636) helpers for the OAuth 2.0 Authorization Code + PKCE flow.
///
/// Desktop apps can't keep a secret confidential, so PKCE binds the auth
/// request to the token exchange: we send `code_challenge` up front and prove
/// possession of the matching `code_verifier` when redeeming the code.
enum PKCE {
    /// A verifier/challenge pair for one authorization attempt.
    struct Pair: Sendable {
        /// High-entropy secret kept locally, sent only at token exchange.
        let verifier: String
        /// `base64url(SHA256(verifier))`, sent in the authorization URL.
        let challenge: String
        /// Always "S256" — Google requires the SHA-256 method.
        let method = "S256"
    }

    /// Generate a fresh PKCE pair (43-char verifier from 32 random bytes).
    static func makePair() -> Pair {
        let verifier = base64URL(randomBytes(32))
        let challenge = codeChallenge(for: verifier)
        return Pair(verifier: verifier, challenge: challenge)
    }

    /// Compute `base64url(SHA256(verifier))` for a given verifier.
    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    // MARK: - Helpers

    private static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let result = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if result != errSecSuccess {
            // Fallback to a non-crypto source only if SecRandom fails.
            for i in 0..<count { bytes[i] = UInt8.random(in: 0...255) }
        }
        return Data(bytes)
    }

    /// Base64url encoding without padding (RFC 4648 §5).
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
