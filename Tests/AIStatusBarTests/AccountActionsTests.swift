import XCTest
@testable import AIStatusBar

final class AccountActionsTests: XCTestCase {
    func testGrokKindIsBuiltinAndDistinctFromCodex() {
        XCTAssertEqual(AccountKind.grok.rawValue, "grok")
        XCTAssertFalse(AccountKind.grok.isCodex)
        XCTAssertFalse(AccountKind.grok.isOwned)
    }

    func testEveryAccountKindRoutesReconnectToItsProvider() {
        XCTAssertEqual(AccountActionPolicy.provider(for: .claudeMain), .claude)
        XCTAssertEqual(AccountActionPolicy.provider(for: .claudeOAuth), .claude)
        XCTAssertEqual(AccountActionPolicy.provider(for: .codex), .codex)
        XCTAssertEqual(AccountActionPolicy.provider(for: .codexOAuth), .codex)
        XCTAssertNil(AccountActionPolicy.provider(for: .grok))
    }

    func testProviderLabelsMatchChooserButtons() {
        XCTAssertEqual(AccountProvider.claude.label, "Claude")
        XCTAssertEqual(AccountProvider.codex.label, "Codex")
    }
}
