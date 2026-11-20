import XCTest
@testable import AIStatusBar

/// Regression coverage for the "sasha@ykv.lv · Claude" duplicate-row bug: a
/// second CLI profile account (default name "Claude 2") shares its owner's
/// email with the main account, so falling back to email for both rows made
/// them render as identical, indistinguishable text.
final class IdentityTests: XCTestCase {
    func testClaude2KeepsItsOwnNameEvenWithKnownEmail() {
        XCTAssertEqual(AccountRowView.resolvedName(name: "Claude 2", email: "sasha@ykv.lv"), "Claude 2")
    }

    func testMainAccountStillPrefersEmailOverGenericName() {
        XCTAssertEqual(AccountRowView.resolvedName(name: "Claude", email: "sasha@ykv.lv"), "sasha@ykv.lv")
    }

    func testTwoAccountsSharingAnEmailResolveToDifferentIdentities() {
        let main = AccountRowView.resolvedName(name: "Claude", email: "sasha@ykv.lv")
        let secondProfile = AccountRowView.resolvedName(name: "Claude 2", email: "sasha@ykv.lv")
        XCTAssertNotEqual(main, secondProfile)
    }

    /// Guards the general rule (checked by pattern, not an enumerated list): any
    /// numbered profile name stays generic-free, not just the one literal that
    /// happened to trigger the original bug.
    func testGenericPlaceholderExcludesAnyNumberedProfileName() {
        XCTAssertFalse(Account.isGenericPlaceholderName("Claude 2"))
        XCTAssertFalse(Account.isGenericPlaceholderName("Claude 3"))
        XCTAssertTrue(Account.isGenericPlaceholderName("Claude"))
        XCTAssertTrue(Account.isGenericPlaceholderName("Codex"))
        XCTAssertTrue(Account.isGenericPlaceholderName("Grok"))
    }

    /// A third profile must not be assigned the same auto-name as an existing
    /// second one — that would recreate the identical-row bug between two
    /// profile accounts instead of between a profile and the main account.
    func testThirdProfileGetsADifferentAutoNameThanTheSecond() {
        let firstProfileName = Account.nextClaudeProfileName(existingConfigDirs: [nil])
        XCTAssertEqual(firstProfileName, "Claude 2")
        let secondProfileName = Account.nextClaudeProfileName(existingConfigDirs: [nil, "/Users/x/.claude-max2"])
        XCTAssertEqual(secondProfileName, "Claude 3")
        XCTAssertNotEqual(firstProfileName, secondProfileName)
    }
}
