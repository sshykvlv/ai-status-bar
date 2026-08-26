import Foundation

/// Демо-режим для обкатки вёрстки без живых аккаунтов: `AISTATUSBAR_MOCK=1
/// build/AIStatusBar.app/Contents/MacOS/AIStatusBar` показывает фиксированный набор
/// состояний — здоровое, «жёлтая зона» и полностью исчерпанное 5h-окно.
/// Ничего не пишет в UserDefaults/Keychain и не ходит в сеть.
enum MockData {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["AISTATUSBAR_MOCK"] != nil
    }

    static let accounts: [Account] = [
        Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Personal", kind: .claudeOAuth, email: "sasha@example.com", plan: "Max 20x"),
        Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                name: "Work", kind: .claudeMain, email: "work@example.com", plan: "Pro"),
        Account(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                name: "Codex", kind: .codex, email: "sasha@example.com", plan: "Plus"),
    ]

    /// Времена сброса считаются от текущего момента, чтобы «сегодня 19:04» и
    /// «Tue 09:00» выглядели живыми в любой момент запуска.
    static func state(for id: UUID) -> AccountState {
        let now = Date()
        switch id {
        case accounts[0].id:   // токены кончились: 5h на нуле, скоро сброс
            return .ok(Usage(
                fiveHour: UsageWindow(utilization: 100, resetsAt: now.addingTimeInterval(82 * 60)),
                sevenDay: UsageWindow(utilization: 87, resetsAt: now.addingTimeInterval(2.6 * 86400))
            ), fetchedAt: now)
        case accounts[1].id:   // рабочая середина + прогноз выгорания (демо burn-rate)
            return .ok(Usage(
                fiveHour: UsageWindow(utilization: 42, resetsAt: now.addingTimeInterval(3.2 * 3600),
                                       projectedExhaustion: now.addingTimeInterval(2 * 3600)),
                sevenDay: UsageWindow(utilization: 18, resetsAt: now.addingTimeInterval(4.8 * 86400))
            ), fetchedAt: now)
        default:               // сохранённые данные + истёкшая app-owned сессия
            return .stale(Usage(
                fiveHour: UsageWindow(utilization: 8, resetsAt: now.addingTimeInterval(4.6 * 3600)),
                sevenDay: UsageWindow(utilization: 74, resetsAt: now.addingTimeInterval(1.9 * 86400))
            ), fetchedAt: now.addingTimeInterval(-12 * 60),
                          badge: MenuPresentation.authFailureBadge)
        }
    }
}
