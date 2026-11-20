import XCTest
@testable import AIStatusBar

final class GrokParserTests: XCTestCase {
    func testPaidWeeklyUsageParsesPercentAndReset() throws {
        let data = Data(#"{"config":{"creditUsagePercent":37.5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-11-22T00:00:00+00:00"}}}"#.utf8)

        let usage = try GrokUsageParser.parse(data)

        XCTAssertNil(usage.fiveHour)
        XCTAssertEqual(usage.sevenDay?.utilization, 37.5)
        XCTAssertEqual(usage.sevenDay?.resetsAt?.timeIntervalSince1970, 1_795_305_600)
    }

    func testFreeUsageWithoutPercentHasNoWindows() throws {
        let data = Data(#"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","end":"2026-11-22T00:00:00+00:00"}}}"#.utf8)

        let usage = try GrokUsageParser.parse(data)

        XCTAssertNil(usage.fiveHour)
        XCTAssertNil(usage.sevenDay)
    }

    func testMonthlyUsageDoesNotPretendToBeWeekly() throws {
        let data = Data(#"{"config":{"creditUsagePercent":42,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_MONTHLY","end":"2026-12-01T00:00:00Z"}}}"#.utf8)

        let usage = try GrokUsageParser.parse(data)

        XCTAssertNil(usage.sevenDay)
    }

    func testSnakeCasePercentAndBillingPeriodFallback() throws {
        let data = Data(#"{"config":{"credit_usage_percent":18,"billingPeriodEnd":"2026-11-22T00:00:00Z"}}"#.utf8)

        let usage = try GrokUsageParser.parse(data)

        XCTAssertEqual(usage.sevenDay?.utilization, 18)
        XCTAssertEqual(usage.sevenDay?.resetsAt?.timeIntervalSince1970, 1_795_305_600)
    }

    func testMissingConfigThrows() {
        XCTAssertThrowsError(try GrokUsageParser.parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? FetchError, .badResponse("grok usage: no config"))
        }
    }
}

final class GrokAuthTests: XCTestCase {
    private func temporaryAuth(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-auth-\(UUID().uuidString).json")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLoadsIssuerEntryAndFractionalExpiration() throws {
        let url = try temporaryAuth(#"""
        {
          "other":{"key":"wrong","user_id":"other"},
          "https://auth.x.ai::client":{"oidc_issuer":"https://auth.x.ai/","key":"secret","user_id":"user-1","email":"grok@example.com","expires_at":"2026-11-20T13:18:10.611206Z"}
        }
        """#)

        let auth = try XCTUnwrap(GrokAuth.load(from: url))

        XCTAssertEqual(auth.accessToken, "secret")
        XCTAssertEqual(auth.userID, "user-1")
        XCTAssertEqual(auth.email, "grok@example.com")
        XCTAssertNotNil(auth.expiresAt)
    }

    func testMissingKeyReturnsNil() throws {
        let url = try temporaryAuth(#"{"entry":{"oidc_issuer":"https://auth.x.ai","user_id":"user-1"}}"#)
        XCTAssertNil(GrokAuth.load(from: url))
    }

    func testExpirationSupportsWholeSecondsAndTreatsUnparseableAsNotExpired() throws {
        let expiredURL = try temporaryAuth(#"{"entry":{"key":"secret","user_id":"user-1","expires_at":"2026-11-20T13:18:10Z"}}"#)
        let invalidURL = try temporaryAuth(#"{"entry":{"key":"secret","user_id":"user-1","expires_at":"not-a-date"}}"#)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertTrue(try XCTUnwrap(GrokAuth.load(from: expiredURL)).isExpired(now: now))
        XCTAssertFalse(try XCTUnwrap(GrokAuth.load(from: invalidURL)).isExpired(now: now))
    }
}

final class GrokProviderTests: XCTestCase {
    private let validAuth = GrokAuth(accessToken: "secret", userID: "user-1",
                                     email: nil, expiresAt: .distantFuture)

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.errorHandler = nil
        MockURLProtocol.rawHandler = nil
        super.tearDown()
    }

    func testSendsBillingHeaders() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString,
                           "https://cli-chat-proxy.grok.com/v1/billing?format=credits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-XAI-Token-Auth"), "xai-grok-cli")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-userid"), "user-1")
            return (200, Data(#"{"config":{"creditUsagePercent":25}}"#.utf8))
        }

        let usage = try await GrokProvider(session: .mocked).fetchUsage(auth: validAuth)

        XCTAssertEqual(usage.sevenDay?.utilization, 25)
    }

    func test401IsUnauthorized() async {
        MockURLProtocol.handler = { _ in (401, Data()) }

        do {
            _ = try await GrokProvider(session: .mocked).fetchUsage(auth: validAuth)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? FetchError, .unauthorized)
        }
    }

    func testExpiredAuthIsUnauthorizedWithoutRequest() async {
        var requests = 0
        MockURLProtocol.handler = { _ in requests += 1; return (200, Data()) }
        let expired = GrokAuth(accessToken: "secret", userID: "user-1",
                               email: nil, expiresAt: .distantPast)

        do {
            _ = try await GrokProvider(session: .mocked).fetchUsage(auth: expired)
            XCTFail("expected unauthorized")
        } catch {
            XCTAssertEqual(error as? FetchError, .unauthorized)
        }
        XCTAssertEqual(requests, 0)
    }
}
