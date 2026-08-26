import XCTest
@testable import AIStatusBar

final class MenuPresentationTests: XCTestCase {
    private let account = Account(id: UUID(), name: "Work", kind: .codexOAuth,
                                  email: "sasha@ykv.lv", plan: "Pro")

    func testApprovedMenuHierarchyHasNoManualRefreshOrLegacyAddActions() {
        XCTAssertEqual(MenuPresentation.topLevelActionTitles,
                       ["Add Account…", "Settings", "About AI Status Bar", "Quit AI Status Bar"])
        XCTAssertEqual(MenuPresentation.settingsActionTitles,
                       ["Launch at Login", "Usage Alerts", "Check for Updates…"])

        let all = MenuPresentation.topLevelActionTitles + MenuPresentation.settingsActionTitles
        XCTAssertFalse(all.contains { $0.localizedCaseInsensitiveContains("refresh") })
        XCTAssertFalse(all.contains { $0.contains("CLI Profile") || $0.contains("Codex Account") })
    }

    func testMenuWidthFitsContentWithoutHeaderSlack() {
        let item = MenuRowFactory.item(for: account, state: .pending)

        XCTAssertLessThanOrEqual(item.view?.frame.width ?? .infinity, 300)
    }

    func testWindowTooltipsIdentifyBothWindowsWithoutAHeader() {
        let fiveHour = UsageWindow(utilization: 42, resetsAt: nil)
        let weekly = UsageWindow(utilization: 18, resetsAt: nil)

        XCTAssertEqual(MenuPresentation.windowTooltip(title: "5-hour window", window: fiveHour),
                       "5-hour window · 42% used")
        XCTAssertEqual(MenuPresentation.windowTooltip(title: "Weekly window", window: weekly),
                       "Weekly window · 18% used")
        XCTAssertEqual(MenuPresentation.windowTooltip(title: "Weekly window", window: nil),
                       "Weekly window · no data")
    }

    func testExpiredStaleAccountRetainsLastDataLanguage() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = Usage(fiveHour: .init(utilization: 12, resetsAt: nil),
                          sevenDay: .init(utilization: 23, resetsAt: nil))
        let state = AccountState.stale(usage, fetchedAt: fetched,
                                       badge: MenuPresentation.authFailureBadge)

        XCTAssertEqual(MenuPresentation.statusLines(for: state,
                                                     now: fetched.addingTimeInterval(720)),
                       ["Session expired", "Last data retained"])
    }

    func testOfflineStaleAccountShowsAccountLevelFreshness() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = Usage(fiveHour: nil, sevenDay: nil)
        let state = AccountState.stale(usage, fetchedAt: fetched, badge: "offline")

        XCTAssertEqual(MenuPresentation.statusLines(for: state,
                                                     now: fetched.addingTimeInterval(720)),
                       ["Offline", "Last updated 12 min ago"])
    }

    func testAccessibilityTitleIncludesIdentityProviderWindowsAndStatus() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = Usage(fiveHour: .init(utilization: 12, resetsAt: nil),
                          sevenDay: .init(utilization: 23, resetsAt: nil))
        let state = AccountState.stale(usage, fetchedAt: fetched,
                                       badge: MenuPresentation.authFailureBadge)

        XCTAssertEqual(MenuPresentation.accessibilityTitle(account: account, state: state),
                       "Work, Codex, 5-hour 12%, week 23%, session expired")
    }

    func testAuthCopyNeverInstructsUserToRepairCLI() {
        for kind in [AccountKind.claudeMain, .claudeOAuth, .codex, .codexOAuth] {
            XCTAssertEqual(MenuPresentation.authFailureBadge(for: kind),
                           MenuPresentation.authFailureBadge)
        }
        XCTAssertEqual(MenuPresentation.authFailureBadge, "sign in again")
    }
}
