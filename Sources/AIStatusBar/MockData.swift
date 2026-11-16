import Foundation

/// Демо-режим для обкатки вёрстки без живых аккаунтов: `AISTATUSBAR_MOCK=1
/// build/AIStatusBar.app/Contents/MacOS/AIStatusBar` показывает фиксированный набор
/// состояний — здоровое, «жёлтая зона» и полностью исчерпанное 5h-окно.
/// Ничего не пишет в UserDefaults/Keychain и не ходит в сеть.
/// Блок «Mac» в мок-режиме показывает `systemSnapshot` и никого не гасит.
/// Скриншоты: `AISTATUSBAR_OPEN_MENU=1 AISTATUSBAR_POPUP=1
/// AISTATUSBAR_APPEARANCE=light|dark` — меню посреди экрана в нужной теме.
enum MockData {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["AISTATUSBAR_MOCK"] != nil
    }

    /// Узкое место — память (критично, своп 16 GB); среди потребителей —
    /// агент с помощниками, приложение и мелкая сирота (живёт в сабменю «Mac»).
    static let systemSnapshot: SystemSnapshot = {
        let gb: (Double) -> UInt64 = { UInt64($0 * 1_073_741_824) }
        func c(_ key: String, _ title: String, _ kind: ConsumerKind, roots: Int, helpers: Int,
               _ size: Double, base: Int32) -> Consumer {
            let all = (0..<Int32(roots + helpers)).map { base + $0 }
            return Consumer(key: key, title: title, kind: kind, rootPids: Array(all.prefix(roots)),
                            allPids: all, footprint: gb(size), cpuPercent: 0, helpers: helpers)
        }
        return SystemSnapshot(
            cpuPercent: 74, memUsed: gb(27.4), memTotal: gb(32), swapUsed: gb(16.2), pressure: .critical,
            consumers: [
                c("agent:Claude Code", "Claude Code", .agent, roots: 11, helpers: 46, 7.4, base: 1000),
                c("app:/Applications/Google Chrome.app", "Google Chrome",
                  .app(bundlePath: "/Applications/Google Chrome.app"), roots: 1, helpers: 38, 4.8, base: 2000),
                c("agent:Codex", "Codex", .agent, roots: 3, helpers: 9, 2.1, base: 3000),
            ],
            leftovers: [Leftover(pid: 7245, label: "relay.py", tool: "uv", age: 7200,
                                 footprint: 9 * 1_048_576, treePids: [7245, 7247])],
            takenAt: Date())
    }()

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
