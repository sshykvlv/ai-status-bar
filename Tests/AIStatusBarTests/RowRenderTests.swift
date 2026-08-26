import XCTest
import SwiftUI
@testable import AIStatusBar

/// Не проверка, а инструмент: рендерит AccountRowView во всех состояниях в PNG,
/// чтобы смотреть вёрстку строки без запуска приложения и открытия меню.
/// Запуск: `AISTATUSBAR_RENDER_DIR=/tmp/rows swift test --filter RowRenderTests`
/// Без переменной окружения — скип (в обычном прогоне ничего не пишет).
final class RowRenderTests: XCTestCase {
    @MainActor
    func testRenderRowStates() throws {
        guard let dir = ProcessInfo.processInfo.environment["AISTATUSBAR_RENDER_DIR"] else {
            throw XCTSkip("set AISTATUSBAR_RENDER_DIR to render row previews")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)   // рендер в тёмной теме
        let now = Date()
        let exhausted = Usage(
            fiveHour: UsageWindow(utilization: 100, resetsAt: now.addingTimeInterval(82 * 60)),
            sevenDay: UsageWindow(utilization: 87, resetsAt: now.addingTimeInterval(2.6 * 86400)))
        let working = Usage(
            fiveHour: UsageWindow(utilization: 42, resetsAt: now.addingTimeInterval(3.2 * 3600),
                                   projectedExhaustion: now.addingTimeInterval(2 * 3600)),
            sevenDay: UsageWindow(utilization: 18, resetsAt: now.addingTimeInterval(4.8 * 86400)))
        let calm = Usage(
            fiveHour: UsageWindow(utilization: 8, resetsAt: now.addingTimeInterval(4.6 * 3600)),
            sevenDay: UsageWindow(utilization: 74, resetsAt: now.addingTimeInterval(1.9 * 86400)))

        let rows: [(String, AccountRowView)] = [
            ("1-exhausted", AccountRowView(name: "Personal", state: .ok(exhausted, fetchedAt: now),
                                           kind: .claudeOAuth, email: "sasha@example.com", plan: "Max 20x")),
            ("2-working", AccountRowView(name: "Work", state: .ok(working, fetchedAt: now),
                                         kind: .claudeMain, email: "work@example.com", plan: "Pro")),
            ("3-calm-yellow7d", AccountRowView(name: "Codex", state: .ok(calm, fetchedAt: now),
                                               kind: .codex, email: "sasha@example.com", plan: "Plus")),
            ("4-stale", AccountRowView(name: "Personal", state: .stale(working, fetchedAt: now, badge: "offline"),
                                       kind: .claudeOAuth, plan: "Max 20x")),
            ("5-pending", AccountRowView(name: "Claude", state: .pending, kind: .claudeMain)),
            ("6-failed", AccountRowView(name: "Codex", state: .failed(badge: MenuPresentation.authFailureBadge), kind: .codex)),
            // Дефолтное имя + известный email → в identity показывается email (V2-B).
            ("7-default-name-email", AccountRowView(name: "Claude", state: .ok(calm, fetchedAt: now),
                                                    kind: .claudeOAuth, email: "sasha.yakovlev@gmail.com", plan: "Max 20x")),
        ]
        // Рендер через NSHostingView + cacheDisplay, как в реальном меню:
        // ImageRenderer теряет текст с динамическими NSColor-label-цветами
        // (secondary/tertiary) — сегменты просто не рисуются.
        for (name, row) in rows {
            let host = NSHostingView(rootView: row)
            host.frame = NSRect(x: 0, y: 0, width: MenuRowFactory.rowWidth, height: MenuRowFactory.rowHeight)
            host.appearance = NSAppearance(named: .darkAqua)
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                XCTFail("render failed for \(name)"); continue
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("png failed for \(name)"); continue
            }
            try png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
}
