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
}
