import Foundation

struct UsageWindow: Equatable {
    let utilization: Double      // 0…100, сколько ИЗРАСХОДОВАНО
    let resetsAt: Date?
    // Прогноз момента исчерпания (100%) при текущем темпе — заполняется Poller'ом
    // только когда он наступает раньше resetsAt (см. BurnRate.swift). Default сохраняет
    // все существующие вызовы UsageWindow(utilization:resetsAt:) компилируемыми.
    var projectedExhaustion: Date? = nil
}

struct Usage: Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    var worstUtilization: Double {
        max(fiveHour?.utilization ?? 0, sevenDay?.utilization ?? 0)
    }
}

enum AccountKind: String, Codable {
    case claudeMain
    case claudeOAuth
    case codex
    case codexOAuth

    var isCodex: Bool { self == .codex || self == .codexOAuth }
    var isOwned: Bool { self == .claudeOAuth || self == .codexOAuth }
}

struct Account: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var kind: AccountKind
    var email: String?
    var plan: String? = nil
    /// Для дополнительных Codex-аккаунтов — путь к их CODEX_HOME (папке с auth.json).
    /// nil = основной автоподхваченный Codex (использует ~/.codex по умолчанию).
    var codexHome: String? = nil
    /// Для дополнительных Claude CLI-профилей — путь к их CLAUDE_CONFIG_DIR.
    /// Claude Code кладёт креды такого профиля в Keychain-сервис с hash-суффиксом
    /// от этого пути (см. KeychainStore.claudeCodeService). nil = основной ~/.claude.
    var claudeConfigDir: String? = nil

    /// True only for the bare, un-numbered placeholder ("Claude"/"Codex") that a
    /// single account of a kind starts with before it's renamed or has a fetched
    /// email. Used as a fallback signal that a row's email (once known) is more
    /// informative than this name — shared by the menubar tooltip and menu rows.
    /// Numbered variants ("Claude 2", "Claude 3", …) are NOT generic: they already
    /// disambiguate sibling accounts, while their email often doesn't (same owner,
    /// multiple subscriptions) — swapping a numbered name for a shared email used
    /// to make sibling rows render as identical, indistinguishable text. Checked by
    /// rule instead of an enumerated set so a third/fourth profile's auto-assigned
    /// name (see AppDelegate.addClaudeProfile) is covered without remembering
    /// to list it here too.
    static func isGenericPlaceholderName(_ name: String) -> Bool {
        name == "Claude" || name == "Codex"
    }

    /// Next auto-assigned name for a new Claude CLI profile account, numbered by
    /// how many profile accounts (non-nil claudeConfigDir) already exist. Never a
    /// fixed literal — a hardcoded "Claude 2" would collide with an existing
    /// profile's name once a third profile is added, reintroducing the identical-
    /// row bug this type was already fixed for once.
    static func nextClaudeProfileName(existingConfigDirs: [String?]) -> String {
        let profileCount = existingConfigDirs.filter { $0 != nil }.count
        return "Claude \(profileCount + 2)"
    }
}

enum AccountState: Equatable {
    case pending                                   // ещё не опрашивали
    case ok(Usage, fetchedAt: Date)
    case stale(Usage, fetchedAt: Date, badge: String) // старые данные + бейдж
    case failed(badge: String)                     // данных нет
}

enum FetchError: Error, Equatable {
    case cancelled           // explicit cancellation must not become an offline state
    case unauthorized        // 401/403 — токен протух/нет scope
    case rateLimited         // 429
    case network(String)
    case badResponse(String)

    static func fromNetwork(_ error: Error) -> FetchError {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        return .network(error.localizedDescription)
    }
}

import AppKit

extension NSColor {
    /// Warn-оранжевый порогов: в тёмной теме — systemOrange, в светлой — более
    /// глубокий янтарный (фидбэк владельца 13.07: systemOrange на светлом фоне
    /// чипа читается слабо). Динамический — резолвится по appearance при отрисовке.
    /// 16.11: #B86600 давал 2.8–3.2:1 на фоне чипа (ниже WCAG AA 4.5) —
    /// углублён до #8F4C00 (4.3–5.0:1, на уровне secondaryLabel).
    static let asbWarn = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemOrange
            : NSColor(srgbRed: 0x8F / 255, green: 0x4C / 255, blue: 0.0, alpha: 1.0)
    }

    /// Danger-красный порогов (фидбэк владельца 16.11: «красный практически не
    /// читается»). systemRed на фоне чипа даёт 2.3–2.7:1 в светлой теме и
    /// 3.2–3.8:1 в тёмной. Замер против фона чипа (#D0D0D0–#E0E0E0 светлая,
    /// #323232–#3C3C3C тёмная): #A8160D → 4.9–5.7:1, #FF8A80 → 4.8–5.6:1.
    /// Залитые плашки порогов (фидбэк владельца 16.11: «инвертировать на плашку
    /// такого цвета»). Текст на них белый; заливка одна для обеих тем, подобрана
    /// под белый ≥4.5:1 — systemOrange с белым даёт 2.1:1, поэтому он темнее.
    static let asbWarnFill = NSColor(srgbRed: 0xB8 / 255, green: 0x5A / 255, blue: 0.0, alpha: 1.0)     // 4.7:1
    static let asbDangerFill = NSColor(srgbRed: 0xD9 / 255, green: 0x2D / 255, blue: 0x20 / 255, alpha: 1.0) // 4.8:1

    static let asbDanger = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xFF / 255, green: 0x8A / 255, blue: 0x80 / 255, alpha: 1.0)
            : NSColor(srgbRed: 0xA8 / 255, green: 0x16 / 255, blue: 0x0D / 255, alpha: 1.0)
    }
}
