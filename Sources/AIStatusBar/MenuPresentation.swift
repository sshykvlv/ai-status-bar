import Foundation

enum MenuPresentation {
    static let topLevelActionTitles = [
        "Add Account…",
        "Settings",
        "About AI Status Bar",
        "Quit AI Status Bar",
    ]
    static let settingsActionTitles = [
        "Launch at Login",
        "Usage Alerts",
        "Check for Updates…",
    ]
    static let authFailureBadge = "sign in again"

    static func authFailureBadge(for kind: AccountKind) -> String {
        authFailureBadge
    }

    static func windowTooltip(title: String, window: UsageWindow?) -> String {
        guard let window else { return "\(title) · no data" }
        return "\(title) · \(Int(window.utilization))% used"
    }

    static func statusLines(for state: AccountState, now: Date = .now) -> [String] {
        switch state {
        case .pending:
            return ["Loading…"]
        case .ok(_, let fetchedAt):
            return [freshness(fetchedAt: fetchedAt, now: now)]
        case .failed(let badge):
            if badge == authFailureBadge { return ["Session expired", "No saved usage data"] }
            if badge == "offline" { return ["Offline", "No recent usage data"] }
            if badge == "rate-limited" { return ["Temporarily rate-limited"] }
            return [badge]
        case .stale(_, let fetchedAt, let badge):
            if badge == authFailureBadge {
                return ["Session expired", freshness(fetchedAt: fetchedAt, now: now)]
            }
            let title = badge == "offline" ? "Offline"
                : badge == "rate-limited" ? "Temporarily rate-limited"
                : badge
            return [title, freshness(fetchedAt: fetchedAt, now: now)]
        }
    }

    static func accessibilityTitle(account: Account, state: AccountState,
                                   now: Date = .now) -> String {
        let identity = Account.isGenericPlaceholderName(account.name)
            ? (account.email ?? account.name)
            : account.name
        let provider = account.kind.isCodex ? "Codex" : "Claude"
        var parts = [identity, provider]
        switch state {
        case .ok(let usage, let fetchedAt):
            parts.append("5-hour \(windowPercent(usage.fiveHour))")
            parts.append("week \(windowPercent(usage.sevenDay))")
            parts.append(freshness(fetchedAt: fetchedAt, now: now).lowercased())
        case .stale(let usage, let fetchedAt, let badge):
            parts.append("5-hour \(windowPercent(usage.fiveHour))")
            parts.append("week \(windowPercent(usage.sevenDay))")
            parts.append(accessibilityStatus(for: badge))
            parts.append(freshness(fetchedAt: fetchedAt, now: now).lowercased())
        case .pending:
            parts.append("loading")
        case .failed(let badge):
            parts.append("no usage data")
            parts.append(accessibilityStatus(for: badge))
        }
        return parts.joined(separator: ", ")
    }

    private static func windowPercent(_ window: UsageWindow?) -> String {
        window.map { "\(Int($0.utilization))%" } ?? "no data"
    }

    private static func accessibilityStatus(for badge: String) -> String {
        if badge == authFailureBadge { return "session expired" }
        if badge == "rate-limited" { return "temporarily rate-limited" }
        return badge
    }

    private static func freshness(fetchedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(fetchedAt)))
        if seconds < 60 { return "Last updated just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "Last updated \(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "Last updated \(hours) hr ago" }
        return "Last updated \(hours / 24) d ago"
    }
}
