import XCTest
@testable import AIStatusBar

final class OAuthTests: XCTestCase {
    private func query(_ url: URL) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .compactMap { item in item.value.map { (item.name, $0) } })
    }

    func testOwnedTokensDecodeLegacyPayloadWithoutIDToken() throws {
        let legacy = OAuthTokens(accessToken: "access", refreshToken: "refresh",
                                 expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
        let data = try JSONEncoder().encode(legacy)

        let decoded = try JSONDecoder().decode(OAuthTokens.self, from: data)

        XCTAssertNil(decoded.idToken)
        XCTAssertEqual(decoded.accessToken, "access")
        XCTAssertEqual(decoded.refreshToken, "refresh")
    }

    func testOwnedTokensRoundTripCodexIDToken() throws {
        let original = OAuthTokens(accessToken: "access", refreshToken: "refresh",
                                   expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
                                   idToken: "identity")

        let data = try JSONEncoder().encode(original)

        XCTAssertEqual(try JSONDecoder().decode(OAuthTokens.self, from: data), original)
    }

    func testPKCEPairIsValid() {
        let pair = PKCE.generate()
        XCTAssertGreaterThanOrEqual(pair.verifier.count, 43)
        XCTAssertFalse(pair.challenge.contains("="))   // base64url, no padding
        XCTAssertFalse(pair.challenge.contains("+"))
        XCTAssertFalse(pair.challenge.contains("/"))
        XCTAssertNotEqual(pair.verifier, pair.challenge)
    }

    func testCallbackParsing() {
        let parsed = OAuthFlow.parseCallback(requestLine: "GET /callback?code=abc123&state=xyz HTTP/1.1")
        XCTAssertEqual(parsed?.code, "abc123")
        XCTAssertEqual(parsed?.state, "xyz")
    }

    func testCallbackParsingRejectsWrongPath() {
        XCTAssertNil(OAuthFlow.parseCallback(requestLine: "GET /favicon.ico HTTP/1.1"))
    }

    func testCodexAuthorizeURLMatchesBrowserPKCEContract() throws {
        let url = CodexOAuthRequest.authorizeURL(challenge: "challenge", state: "state")
        let items = query(url)

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(url.path, "/oauth/authorize")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["client_id"], CodexOAuthConstants.clientID)
        XCTAssertEqual(items["redirect_uri"], CodexOAuthConstants.redirectURI)
        XCTAssertEqual(items["scope"], "openid profile email offline_access api.connectors.read api.connectors.invoke")
        XCTAssertEqual(items["code_challenge"], "challenge")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["id_token_add_organizations"], "true")
        XCTAssertEqual(items["codex_cli_simplified_flow"], "true")
        XCTAssertEqual(items["state"], "state")
        XCTAssertEqual(items["originator"], "codex_cli_rs")
    }

    func testCodexCallbackParsingUsesAllowlistedPath() {
        let parsed = CodexOAuthRequest.parseCallback(
            requestLine: "GET /auth/callback?code=abc123&state=xyz HTTP/1.1")
        XCTAssertEqual(parsed?.code, "abc123")
        XCTAssertEqual(parsed?.state, "xyz")
        XCTAssertNil(CodexOAuthRequest.parseCallback(
            requestLine: "GET /callback?code=abc123&state=xyz HTTP/1.1"))
    }
}
