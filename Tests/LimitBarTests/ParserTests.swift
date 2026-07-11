import XCTest
@testable import LimitBar

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

    func testCodexMissingRateLimitThrows() {
        XCTAssertThrowsError(try CodexUsageParser.parse(Data("{}".utf8)))
    }

    func testCodexMissingWindowsIsNil() throws {
        let usage = try CodexUsageParser.parse(Data(#"{"rate_limit":{}}"#.utf8))
        XCTAssertNil(usage.fiveHour); XCTAssertNil(usage.sevenDay)
    }
}
