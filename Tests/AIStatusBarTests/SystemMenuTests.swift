import XCTest
import AppKit
@testable import AIStatusBar

@MainActor
final class SystemMenuTests: XCTestCase {
    private func titles(_ menu: NSMenu?) -> [String] { menu?.items.map(\.title) ?? [] }

    func testMenuItemsShape() throws {
        let items = SystemMenuController(mock: true).items()
        XCTAssertEqual(items.count, 1 + SystemModel.visibleConsumers)
        XCTAssertEqual(items[0].title, "Mac — Swap 16 GB")
        XCTAssertEqual(items.dropFirst().map(\.title), ["Claude Code", "Google Chrome", "Codex"])

        let summary = titles(items[0].submenu)
        XCTAssertTrue(summary.contains("Memory pressure is critical"))
        XCTAssertTrue(summary.contains("Leftovers ×1 · 9 MB"))
        XCTAssertTrue(summary.contains("Open Activity Monitor"))
        let leftovers = try XCTUnwrap(items[0].submenu?.items.first { $0.title.hasPrefix("Leftovers") })
        XCTAssertTrue(titles(leftovers.submenu).contains("relay.py — uv · 2 h · 9 MB"))

        let claude = titles(items[1].submenu)
        XCTAssertEqual(claude.first, "11 processes · 46 helpers · 7.4 GB")
        XCTAssertTrue(claude.contains("Quit All 11"))
        XCTAssertTrue(claude.contains("Force Quit All 11"))
        XCTAssertTrue(titles(items[2].submenu).contains("Quit"))
    }

    func testOpenMenuKeepsRowsAndCount() {
        let controller = SystemMenuController(mock: true)
        let items = controller.items()
        controller.menuWillOpen()
        controller.refreshInPlace()
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.dropFirst().map(\.title), ["Claude Code", "Google Chrome", "Codex"])
        XCTAssertFalse(items.contains { $0.isHidden })
    }

    func testActionTargetIsFrozenAtSubmenuBuild() throws {
        let controller = SystemMenuController(mock: true)
        let items = controller.items()
        let quit = try XCTUnwrap(items[1].submenu?.items.first { $0.title == "Quit All 11" })
        let target = try XCTUnwrap(quit.representedObject as? SystemMenuController.ActionTarget)
        // Цель зафиксирована при построении сабменю: новый замер, пока меню
        // открыто, не добавит в «Quit All 11» двенадцатую сессию.
        XCTAssertEqual(target.consumer?.rootPids.count, 11)
        let left = try XCTUnwrap(items[0].submenu?.items.first { $0.title.hasPrefix("Leftovers") }?.submenu)
        let one = try XCTUnwrap(left.items.first { $0.title.hasPrefix("relay.py") })
        XCTAssertEqual((one.representedObject as? SystemMenuController.ActionTarget)?.leftovers.map(\.pid), [7245])
    }

    func testConfirmTitles() {
        let s = MockData.systemSnapshot
        XCTAssertEqual(SystemMenuController.confirmTitle(s.consumers[0], force: false),
                       "Quit 11 Claude Code sessions?")
        XCTAssertNil(SystemMenuController.confirmTitle(s.consumers[1], force: false))   // приложение спросит само
        XCTAssertEqual(SystemMenuController.confirmTitle(s.consumers[1], force: true),
                       "Force quit Google Chrome?")
        XCTAssertEqual(SystemMenuController.age(45), "1 min")
        XCTAssertEqual(SystemMenuController.age(7200), "2 h")
        XCTAssertEqual(SystemMenuController.age(3 * 86400), "3 d")
    }
}
