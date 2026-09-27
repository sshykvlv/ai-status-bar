import XCTest
@testable import AIStatusBar

final class ParserTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json")!
        return try Data(contentsOf: url)
    }

    func testClaudeParsesLiveFixture() throws {
        let usage = try ClaudeUsageParser.parse(try fixture("claude-usage"))
        let fh = try XCTUnwrap(usage.fiveHour)
        XCTAssert((0...100).contains(fh.utilization))
        XCTAssertNotNil(fh.resetsAt)
        let sd = try XCTUnwrap(usage.sevenDay)
        XCTAssert((0...100).contains(sd.utilization))
    }

    func testClaudeMissingWindowsIsNotCrash() throws {
        let usage = try ClaudeUsageParser.parse(Data("{}".utf8))
        XCTAssertNil(usage.fiveHour); XCTAssertNil(usage.sevenDay)
    }

    func testCodexParsesLiveFixture() throws {
        let usage = try CodexUsageParser.parse(try fixture("codex-usage"))
        let fh = try XCTUnwrap(usage.fiveHour)
        XCTAssert((0...100).contains(fh.utilization))
        XCTAssertNotNil(fh.resetsAt)
        let sd = try XCTUnwrap(usage.sevenDay)
        XCTAssert((0...100).contains(sd.utilization))
        XCTAssertNotNil(sd.resetsAt)
    }

    func testCodexClassifiesSingleWeeklyPrimaryWindowByDuration() throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":35,"limit_window_seconds":604800,"reset_at":1788355537},"secondary_window":null}}"#.utf8)

        let usage = try CodexUsageParser.parse(data)

        XCTAssertNil(usage.fiveHour)
        XCTAssertEqual(usage.sevenDay?.utilization, 35)
        XCTAssertEqual(usage.sevenDay?.resetsAt, Date(timeIntervalSince1970: 1_788_355_537))
    }

    func testCodexWindowWithoutUsedPercentIsMissingRatherThanZero() throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"limit_window_seconds":18000,"reset_at":1788355537},"secondary_window":{"used_percent":42,"limit_window_seconds":604800}}}"#.utf8)

        let usage = try CodexUsageParser.parse(data)

        XCTAssertNil(usage.fiveHour)
        XCTAssertEqual(usage.sevenDay?.utilization, 42)
    }

    func testCodexFallsBackToLegacyWindowPositionsWhenDurationsAreMissing() throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":12},"secondary_window":{"used_percent":34}}}"#.utf8)

        let usage = try CodexUsageParser.parse(data)

        XCTAssertEqual(usage.fiveHour?.utilization, 12)
        XCTAssertEqual(usage.sevenDay?.utilization, 34)
    }

    func testCodexMissingRateLimitThrows() {
        XCTAssertThrowsError(try CodexUsageParser.parse(Data("{}".utf8)))
    }

    func testCodexMissingWindowsIsNil() throws {
        let usage = try CodexUsageParser.parse(Data(#"{"rate_limit":{}}"#.utf8))
        XCTAssertNil(usage.fiveHour); XCTAssertNil(usage.sevenDay)
    }
}
