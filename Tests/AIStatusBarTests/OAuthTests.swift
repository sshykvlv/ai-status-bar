import XCTest
@testable import AIStatusBar

final class OAuthTests: XCTestCase {
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
}
