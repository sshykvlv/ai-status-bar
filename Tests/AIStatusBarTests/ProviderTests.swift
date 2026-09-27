import XCTest
@testable import AIStatusBar

final class ProviderTests: XCTestCase {
    private func jwt(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "e30.\(data.base64URLEncoded()).sig"
    }

    private func form(_ request: URLRequest) throws -> [String: String] {
        let body = try XCTUnwrap(bodyData(request).flatMap { String(data: $0, encoding: .utf8) })
        let items = URLComponents(string: "?\(body)")?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.value.map { (item.name, $0) }
        })
    }

    private func bodyData(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            result.append(buffer, count: count)
        }
        return result
    }

    func testOwnTokensRoundtrip() throws {
        let id = UUID()
        defer { KeychainStore.deleteOwn(accountID: id) }
        let t = OAuthTokens(accessToken: "test-access", refreshToken: "test-refresh",
                            expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        try KeychainStore.saveOwn(t, accountID: id)
        XCTAssertEqual(KeychainStore.loadOwn(accountID: id), t)
        KeychainStore.deleteOwn(accountID: id)
        XCTAssertNil(KeychainStore.loadOwn(accountID: id))
    }

    func testOwnTokensCanBeReplacedAfterRefreshRotation() throws {
        let id = UUID()
        defer { KeychainStore.deleteOwn(accountID: id) }
        let original = OAuthTokens(accessToken: "old-access", refreshToken: "old-refresh",
                                   expiresAt: Date(timeIntervalSince1970: 1_900_000_000))
        let rotated = OAuthTokens(accessToken: "new-access", refreshToken: "new-refresh",
                                  expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
                                  idToken: "new-identity")

        try KeychainStore.saveOwn(original, accountID: id)
        try KeychainStore.saveOwn(rotated, accountID: id)

        XCTAssertEqual(KeychainStore.loadOwn(accountID: id), rotated)
    }

    // Opt-in: чтение чужой записи "Claude Code-credentials" вызывает блокирующий
    // диалог Keychain у любого, кто запускает тесты. Гоняем только когда явно просят:
    // AISTATUSBAR_TEST_KEYCHAIN=1 swift test
    func testClaudeCodeTokensReadableOnOwnerMachine() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AISTATUSBAR_TEST_KEYCHAIN"] == "1",
                          "set AISTATUSBAR_TEST_KEYCHAIN=1 to exercise real Keychain read")
        // На машине владельца запись существует; смок-проверка парсинга без вывода значений.
        if let t = KeychainStore.claudeCodeTokens() {
            XCTAssertGreaterThan(t.accessToken.count, 20)
            XCTAssertGreaterThan(t.expiresAt.timeIntervalSince1970, 1_700_000_000)
        }
    }

    func testClaudeProviderSuccess() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            XCTAssertTrue(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("claude-code/") ?? false)
            return (200, Data(#"{"five_hour":{"utilization":42,"resets_at":"2026-07-11T18:00:00Z"},"seven_day":{"utilization":13,"resets_at":"2026-07-14T09:00:00Z"}}"#.utf8))
        }
        let usage = try await ClaudeProvider(session: .mocked).fetchUsage(accessToken: "tok")
        XCTAssertEqual(usage.fiveHour?.utilization, 42)
    }

    func testClaudeProvider401() async {
        MockURLProtocol.handler = { _ in (401, Data()) }
        do { _ = try await ClaudeProvider(session: .mocked).fetchUsage(accessToken: "tok"); XCTFail() }
        catch { XCTAssertEqual(error as? FetchError, .unauthorized) }
    }

    func testClaudeProvider429() async {
        MockURLProtocol.handler = { _ in (429, Data()) }
        do { _ = try await ClaudeProvider(session: .mocked).fetchUsage(accessToken: "tok"); XCTFail() }
        catch { XCTAssertEqual(error as? FetchError, .rateLimited) }
    }

    func testClaudeProviderPreservesURLSessionCancellation() async {
        MockURLProtocol.errorHandler = { _ in URLError(.cancelled) }
        defer { MockURLProtocol.errorHandler = nil }
        do { _ = try await ClaudeProvider(session: .mocked).fetchUsage(accessToken: "tok"); XCTFail() }
        catch { XCTAssertEqual(error as? FetchError, .cancelled) }
    }

    // A non-HTTP URLResponse must degrade to a typed error, not crash the whole menu
    // bar app via a force-cast — this is a background poller running every 60s forever.
    func testClaudeProviderNonHTTPResponseThrowsInsteadOfCrashing() async {
        MockURLProtocol.rawHandler = { req in
            (URLResponse(url: req.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
        }
        defer { MockURLProtocol.rawHandler = nil }
        do { _ = try await ClaudeProvider(session: .mocked).fetchUsage(accessToken: "tok"); XCTFail() }
        catch { XCTAssertEqual(error as? FetchError, .badResponse("non-HTTP response")) }
    }

    func testClaudeProviderRefreshNonHTTPResponseThrowsInsteadOfCrashing() async {
        MockURLProtocol.rawHandler = { req in
            (URLResponse(url: req.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
        }
        defer { MockURLProtocol.rawHandler = nil }
        let tokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date())
        do { _ = try await ClaudeProvider(session: .mocked).refresh(tokens); XCTFail() }
        catch { XCTAssertEqual(error as? FetchError, .unauthorized) }
    }

    func testClaudeProviderFetchProfileSuccess() async throws {
        MockURLProtocol.handler = { req in
            XCTAssertTrue(req.url!.absoluteString.hasSuffix("/api/oauth/profile"))
            XCTAssertEqual(req.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
            return (200, Data(#"{"account":{"email":"sasha@ykv.lv","full_name":"Sasha"},"organization":{"rate_limit_tier":"default_claude_max_20x"}}"#.utf8))
        }
        let profile = try await ClaudeProvider(session: .mocked).fetchProfile(accessToken: "tok")
        XCTAssertEqual(profile.email, "sasha@ykv.lv")
        XCTAssertEqual(profile.planLabel, "Max 20x")
    }

    func testClaudeProviderFetchProfile401() async {
        MockURLProtocol.handler = { _ in (401, Data()) }
        do { _ = try await ClaudeProvider(session: .mocked).fetchProfile(accessToken: "tok"); XCTFail() }
        catch { XCTAssertEqual(error as? FetchError, .unauthorized) }
    }

    func testClaudeProviderFetchProfileNonHTTPResponseThrowsInsteadOfCrashing() async {
        MockURLProtocol.rawHandler = { req in
            (URLResponse(url: req.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
        }
        defer { MockURLProtocol.rawHandler = nil }
        do { _ = try await ClaudeProvider(session: .mocked).fetchProfile(accessToken: "tok"); XCTFail() }
        catch { XCTAssertEqual(error as? FetchError, .badResponse("non-HTTP response")) }
    }

    func testPlanLabelMapping() throws {
        func label(_ tier: String) throws -> String? {
            let data = Data(#"{"account":{},"organization":{"rate_limit_tier":"\#(tier)"}}"#.utf8)
            return try ClaudeProvider.parseProfile(data).planLabel
        }
        XCTAssertEqual(try label("default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(try label("default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(try label("default_claude_pro"), "Pro")
        XCTAssertEqual(try label("default_claude_team"), "Team")
        XCTAssertNil(try label("something_else"))
    }

    func testCodexAuthFileParsing() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("auth-test.json")
        try #"{"tokens":{"access_token":"at","refresh_token":"rt","account_id":"acc"},"last_refresh":"2026-07-01T00:00:00Z"}"#
            .write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let auth = try XCTUnwrap(CodexAuth.load(from: tmp))
        XCTAssertEqual(auth.accessToken, "at")
        XCTAssertEqual(auth.refreshToken, "rt")
    }

    func testCodexAuthMissingFileIsNil() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID()).json")
        XCTAssertNil(CodexAuth.load(from: missing))
    }

    func testCodexAuthEmailDecodesIDTokenJWT() throws {
        // Payload: {"email": "sasha@ykv.lv", "sub": "123"} — base64url, no padding, dummy header/sig.
        let idToken = "eyJhbGciOiJIUzI1NiJ9.eyJlbWFpbCI6ICJzYXNoYUB5a3YubHYiLCAic3ViIjogIjEyMyJ9.sig"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("auth-jwt-\(UUID()).json")
        try #"{"tokens":{"access_token":"at","refresh_token":"rt","id_token":"\#(idToken)"}}"#
            .write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let auth = try XCTUnwrap(CodexAuth.load(from: tmp))
        XCTAssertEqual(auth.email(), "sasha@ykv.lv")
    }

    func testCodexAuthEmailNilWithoutIDToken() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("auth-noidt-\(UUID()).json")
        try #"{"tokens":{"access_token":"at","refresh_token":"rt"}}"#
            .write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let auth = try XCTUnwrap(CodexAuth.load(from: tmp))
        XCTAssertNil(auth.email())
    }

    func testCodexProviderSuccess() async throws {
        MockURLProtocol.handler = { _ in
            (200, Data(#"{"rate_limit":{"primary_window":{"used_percent":12,"reset_at":1784360440},"secondary_window":{"used_percent":23,"reset_at":1784360440}}}"#.utf8))
        }
        let usage = try await CodexProvider(session: .mocked).fetchUsage(accessToken: "at")
        XCTAssertEqual(usage.fiveHour?.utilization, 12)
        XCTAssertEqual(usage.sevenDay?.utilization, 23)
    }

    func testCodexProvider401() async {
        MockURLProtocol.handler = { _ in (401, Data()) }
        do { _ = try await CodexProvider(session: .mocked).fetchUsage(accessToken: "at"); XCTFail() }
        catch { XCTAssertEqual(error as? FetchError, .unauthorized) }
    }

    func testCodexProviderNonHTTPResponseThrowsInsteadOfCrashing() async {
        MockURLProtocol.rawHandler = { req in
            (URLResponse(url: req.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
        }
        defer { MockURLProtocol.rawHandler = nil }
        do { _ = try await CodexProvider(session: .mocked).fetchUsage(accessToken: "at"); XCTFail() }
        catch { XCTAssertEqual(error as? FetchError, .badResponse("non-HTTP response")) }
    }

    func testCodexProviderRefreshNonHTTPResponseThrowsInsteadOfCrashing() async {
        MockURLProtocol.rawHandler = { req in
            (URLResponse(url: req.url!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil), Data())
        }
        defer { MockURLProtocol.rawHandler = nil }
        let tokens = OAuthTokens(accessToken: "a", refreshToken: "r", expiresAt: Date(), idToken: nil)
        do { _ = try await CodexProvider(session: .mocked).refresh(tokens); XCTFail() }
        catch { XCTAssertEqual(error as? FetchError, .unauthorized) }
    }

    func testCodexAuthorizationCodeExchangeUsesFormEncoding() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let access = try jwt(["exp": now.addingTimeInterval(3600).timeIntervalSince1970])
        let id = try jwt([
            "email": "sasha@ykv.lv",
            "https://api.openai.com/auth": ["chatgpt_plan_type": "pro"],
        ])
        var capturedForm: [String: String]?
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, CodexOAuthConstants.tokenURL)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"),
                           "application/x-www-form-urlencoded")
            capturedForm = try? self.form(request)
            let body = try! JSONSerialization.data(withJSONObject: [
                "access_token": access,
                "refresh_token": "refresh-new",
                "id_token": id,
            ])
            return (200, body)
        }

        let tokens = try await CodexProvider(session: .mocked).exchangeAuthorizationCode(
            code: "code with spaces", verifier: "verifier/value", now: now)

        XCTAssertEqual(capturedForm, [
            "grant_type": "authorization_code",
            "code": "code with spaces",
            "redirect_uri": CodexOAuthConstants.redirectURI,
            "client_id": CodexOAuthConstants.clientID,
            "code_verifier": "verifier/value",
        ])
        XCTAssertEqual(tokens.accessToken, access)
        XCTAssertEqual(tokens.refreshToken, "refresh-new")
        XCTAssertEqual(tokens.idToken, id)
        XCTAssertEqual(tokens.expiresAt, now.addingTimeInterval(3600))
    }

    func testCodexRefreshPersistsEveryRotatedToken() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let access = try jwt(["exp": now.addingTimeInterval(7200).timeIntervalSince1970])
        let old = OAuthTokens(accessToken: "access-old", refreshToken: "refresh-old",
                              expiresAt: now, idToken: "identity-old")
        var capturedFields: [String: String]?
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            if let body = self.bodyData(request) {
                capturedFields = try? JSONSerialization.jsonObject(with: body) as? [String: String]
            }
            let response = try! JSONSerialization.data(withJSONObject: [
                "access_token": access,
                "refresh_token": "refresh-new",
                "id_token": "identity-new",
            ])
            return (200, response)
        }

        let refreshed = try await CodexProvider(session: .mocked).refresh(old, now: now)

        XCTAssertEqual(capturedFields, [
            "client_id": CodexOAuthConstants.clientID,
            "grant_type": "refresh_token",
            "refresh_token": "refresh-old",
        ])
        XCTAssertEqual(refreshed.accessToken, access)
        XCTAssertEqual(refreshed.refreshToken, "refresh-new")
        XCTAssertEqual(refreshed.idToken, "identity-new")
        XCTAssertEqual(refreshed.expiresAt, now.addingTimeInterval(7200))
    }

    func testCodexRefreshKeepsTokensOmittedByResponse() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let access = try jwt(["exp": now.addingTimeInterval(1800).timeIntervalSince1970])
        let old = OAuthTokens(accessToken: "access-old", refreshToken: "refresh-old",
                              expiresAt: now, idToken: "identity-old")
        MockURLProtocol.handler = { _ in
            let response = try! JSONSerialization.data(withJSONObject: ["access_token": access])
            return (200, response)
        }

        let refreshed = try await CodexProvider(session: .mocked).refresh(old, now: now)

        XCTAssertEqual(refreshed.refreshToken, "refresh-old")
        XCTAssertEqual(refreshed.idToken, "identity-old")
    }

    func testCodexJWTReadsIdentityPlanAndExpiration() throws {
        let expiry = Date(timeIntervalSince1970: 1_900_000_000)
        let token = try jwt([
            "exp": expiry.timeIntervalSince1970,
            "https://api.openai.com/profile": ["email": "profile@ykv.lv"],
            "https://api.openai.com/auth": ["chatgpt_plan_type": "plus"],
        ])

        XCTAssertEqual(CodexJWT.email(token), "profile@ykv.lv")
        XCTAssertEqual(CodexJWT.plan(token), "Plus")
        XCTAssertEqual(CodexJWT.expiration(token), expiry)
    }
}
