import XCTest
@testable import AIStatusBar

final class AccountActionsTests: XCTestCase {
    func testEveryAccountKindRoutesReconnectToItsProvider() {
        XCTAssertEqual(AccountActionPolicy.provider(for: .claudeMain), .claude)
        XCTAssertEqual(AccountActionPolicy.provider(for: .claudeOAuth), .claude)
        XCTAssertEqual(AccountActionPolicy.provider(for: .codex), .codex)
        XCTAssertEqual(AccountActionPolicy.provider(for: .codexOAuth), .codex)
    }

    func testProviderLabelsMatchChooserButtons() {
        XCTAssertEqual(AccountProvider.claude.label, "Claude")
        XCTAssertEqual(AccountProvider.codex.label, "Codex")
    }
}
