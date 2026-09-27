import XCTest
import AppKit
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

        XCTAssertEqual(item.view?.frame.width, 260)
    }

    func testAccountRowStretchesAcrossFinalMenuWidth() throws {
        let item = MenuRowFactory.item(for: account, state: .pending)
        let row = try XCTUnwrap(item.view)
        let container = NSView(frame: row.frame)
        container.addSubview(row)

        container.setFrameSize(NSSize(width: 320, height: row.frame.height))

        XCTAssertEqual(row.frame.width, 320)
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

    func testExpiredStaleAccountShowsRetainedDataAge() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = Usage(fiveHour: .init(utilization: 12, resetsAt: nil),
                          sevenDay: .init(utilization: 23, resetsAt: nil))
        let state = AccountState.stale(usage, fetchedAt: fetched,
                                       badge: MenuPresentation.authFailureBadge)

        XCTAssertEqual(MenuPresentation.statusLines(for: state,
                                                     now: fetched.addingTimeInterval(720)),
                       ["Session expired", "Last updated 12 min ago"])
    }

    func testOfflineStaleAccountShowsAccountLevelFreshness() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = Usage(fiveHour: nil, sevenDay: nil)
        let state = AccountState.stale(usage, fetchedAt: fetched, badge: "offline")

        XCTAssertEqual(MenuPresentation.statusLines(for: state,
                                                     now: fetched.addingTimeInterval(720)),
                       ["Offline", "Last updated 12 min ago"])
    }

    func testHealthyAccountSubmenuShowsWhenDataWasUpdated() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = Usage(fiveHour: nil, sevenDay: nil)
        let state = AccountState.ok(usage, fetchedAt: fetched)

        XCTAssertEqual(MenuPresentation.statusLines(for: state,
                                                     now: fetched.addingTimeInterval(720)),
                       ["Last updated 12 min ago"])
    }

    func testAccessibilityTitleIncludesIdentityProviderWindowsAndStatus() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = Usage(fiveHour: .init(utilization: 12, resetsAt: nil),
                          sevenDay: .init(utilization: 23, resetsAt: nil))
        let state = AccountState.stale(usage, fetchedAt: fetched,
                                       badge: MenuPresentation.authFailureBadge)

        XCTAssertEqual(MenuPresentation.accessibilityTitle(account: account, state: state,
                                                            now: fetched.addingTimeInterval(720)),
                       "Work, Codex, 5-hour 12%, week 23%, session expired, last updated 12 min ago")
    }

    func testHealthyAccessibilityTitleIncludesDataFreshness() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = Usage(fiveHour: .init(utilization: 12, resetsAt: nil),
                          sevenDay: .init(utilization: 23, resetsAt: nil))
        let state = AccountState.ok(usage, fetchedAt: fetched)

        XCTAssertEqual(MenuPresentation.accessibilityTitle(account: account, state: state,
                                                            now: fetched.addingTimeInterval(720)),
                       "Work, Codex, 5-hour 12%, week 23%, last updated 12 min ago")
    }

    func testStaleAccessibilityTitleNamesFailureReasonAndFreshness() {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = Usage(fiveHour: nil, sevenDay: nil)
        let state = AccountState.stale(usage, fetchedAt: fetched, badge: "offline")

        XCTAssertEqual(MenuPresentation.accessibilityTitle(account: account, state: state,
                                                            now: fetched.addingTimeInterval(720)),
                       "Work, Codex, 5-hour no data, week no data, offline, last updated 12 min ago")
    }

    func testFailedAccessibilityTitleNamesWhyDataIsUnavailable() {
        let cases = [
            ("offline", "Work, Codex, no usage data, offline"),
            ("rate-limited", "Work, Codex, no usage data, temporarily rate-limited"),
            (MenuPresentation.authFailureBadge, "Work, Codex, no usage data, session expired"),
        ]

        for (badge, expected) in cases {
            XCTAssertEqual(MenuPresentation.accessibilityTitle(
                account: account,
                state: .failed(badge: badge)
            ), expected)
        }
    }

    func testAuthCopyNeverInstructsUserToRepairCLI() {
        for kind in [AccountKind.claudeMain, .claudeOAuth, .codex, .codexOAuth] {
            XCTAssertEqual(MenuPresentation.authFailureBadge(for: kind),
                           MenuPresentation.authFailureBadge)
        }
        XCTAssertEqual(MenuPresentation.authFailureBadge, "sign in again")
    }
}
