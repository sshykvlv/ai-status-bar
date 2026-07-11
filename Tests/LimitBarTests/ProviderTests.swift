import XCTest
@testable import LimitBar

final class ProviderTests: XCTestCase {
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

    // Opt-in: чтение чужой записи "Claude Code-credentials" вызывает блокирующий
    // диалог Keychain у любого, кто запускает тесты. Гоняем только когда явно просят:
    // LIMITBAR_TEST_KEYCHAIN=1 swift test
    func testClaudeCodeTokensReadableOnOwnerMachine() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIMITBAR_TEST_KEYCHAIN"] == "1",
                          "set LIMITBAR_TEST_KEYCHAIN=1 to exercise real Keychain read")
        // На машине владельца запись существует; смок-проверка парсинга без вывода значений.
        if let t = KeychainStore.claudeCodeTokens() {
            XCTAssertGreaterThan(t.accessToken.count, 20)
            XCTAssertGreaterThan(t.expiresAt.timeIntervalSince1970, 1_700_000_000)
        }
    }
}
