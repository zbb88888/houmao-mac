//
//  GoogleAuthTests.swift
//  houmaoTests
//

import Testing
import Foundation
@testable import houmao

struct GoogleAuthTests {

    // MARK: - PKCE

    @Test func pkcePairIsUrlSafeAndConsistent() {
        let pair = PKCE.makePair()
        #expect(pair.method == "S256")
        #expect(!pair.verifier.isEmpty)
        // base64url alphabet only: no '+', '/', or '='.
        for token in [pair.verifier, pair.challenge] {
            #expect(!token.contains("+"))
            #expect(!token.contains("/"))
            #expect(!token.contains("="))
        }
        // Challenge is deterministic for a given verifier.
        #expect(PKCE.codeChallenge(for: pair.verifier) == pair.challenge)
    }

    @Test func pkcePairsAreUnique() {
        #expect(PKCE.makePair().verifier != PKCE.makePair().verifier)
    }

    // MARK: - Authorization URL

    private func provider() -> GoogleAuthProvider {
        GoogleAuthProvider(config: .init(
            clientID: "client-123",
            redirectURI: "http://127.0.0.1:5555",
            scopes: [GoogleAuthProvider.Scope.gmailModify]
        ))
    }

    @Test func authorizationURLHasRequiredParams() async throws {
        let pkce = PKCE.makePair()
        let url = try await provider().authorizationURL(pkce: pkce, state: "state-xyz")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }

        #expect(value("client_id") == "client-123")
        #expect(value("response_type") == "code")
        #expect(value("code_challenge") == pkce.challenge)
        #expect(value("code_challenge_method") == "S256")
        #expect(value("state") == "state-xyz")
        #expect(value("access_type") == "offline")
        #expect(value("scope") == GoogleAuthProvider.Scope.gmailModify)
    }

    // MARK: - Code extraction

    @Test func extractCodeSucceedsOnMatchingState() throws {
        let url = URL(string: "http://127.0.0.1:5555/?state=abc&code=auth-code-1")!
        let code = try GoogleAuthProvider.extractCode(from: url, expectedState: "abc")
        #expect(code == "auth-code-1")
    }

    @Test func extractCodeRejectsStateMismatch() {
        let url = URL(string: "http://127.0.0.1:5555/?state=wrong&code=x")!
        #expect(throws: MailProviderError.self) {
            try GoogleAuthProvider.extractCode(from: url, expectedState: "abc")
        }
    }

    @Test func extractCodeSurfacesProviderError() {
        let url = URL(string: "http://127.0.0.1:5555/?error=access_denied&state=abc")!
        #expect(throws: MailProviderError.self) {
            try GoogleAuthProvider.extractCode(from: url, expectedState: "abc")
        }
    }

    // MARK: - Form encoding

    @Test func formURLEncodingEscapesReserved() {
        let encoded = GoogleAuthProvider.formURLEncoded(["a b": "c/d"])
        #expect(encoded == "a%20b=c%2Fd")
    }
}
