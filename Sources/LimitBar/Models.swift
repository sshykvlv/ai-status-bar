import Foundation

struct UsageWindow: Equatable {
    let utilization: Double      // 0…100, сколько ИЗРАСХОДОВАНО
    let resetsAt: Date?
}

struct Usage: Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    var worstUtilization: Double {
        max(fiveHour?.utilization ?? 0, sevenDay?.utilization ?? 0)
    }
}

enum AccountKind: String, Codable { case claudeMain, claudeOAuth, codex }

struct Account: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    let kind: AccountKind
    var email: String?
}

enum AccountState: Equatable {
    case pending                                   // ещё не опрашивали
    case ok(Usage, fetchedAt: Date)
    case stale(Usage, fetchedAt: Date, badge: String) // старые данные + бейдж
    case failed(badge: String)                     // данных нет
}

enum FetchError: Error, Equatable {
    case unauthorized        // 401/403 — токен протух/нет scope
    case rateLimited         // 429
    case network(String)
    case badResponse(String)
}
