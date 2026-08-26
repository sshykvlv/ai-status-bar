import Foundation

enum MenuPresentation {
    static let columnLabels = ["ACCOUNT", "5H", "WEEK"]
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

    static func statusLines(for state: AccountState, now: Date = .now) -> [String] {
        switch state {
        case .pending:
            return ["Loading…"]
        case .ok:
            return []
        case .failed(let badge):
            if badge == authFailureBadge { return ["Session expired", "No saved usage data"] }
            if badge == "offline" { return ["Offline", "No recent usage data"] }
            if badge == "rate-limited" { return ["Temporarily rate-limited"] }
            return [badge]
        case .stale(_, let fetchedAt, let badge):
            if badge == authFailureBadge { return ["Session expired", "Last data retained"] }
            let title = badge == "offline" ? "Offline"
                : badge == "rate-limited" ? "Temporarily rate-limited"
                : badge
            return [title, freshness(fetchedAt: fetchedAt, now: now)]
        }
    }

    static func accessibilityTitle(account: Account, state: AccountState) -> String {
        let identity = Account.isGenericPlaceholderName(account.name)
            ? (account.email ?? account.name)
            : account.name
        let provider = account.kind.isCodex ? "Codex" : "Claude"
        var parts = [identity, provider]
        switch state {
        case .ok(let usage, _), .stale(let usage, _, _):
            parts.append("5-hour \(windowPercent(usage.fiveHour))")
            parts.append("week \(windowPercent(usage.sevenDay))")
        case .pending:
            parts.append("loading")
        case .failed:
            parts.append("no usage data")
        }
        if case .stale(_, _, let badge) = state, badge == authFailureBadge {
            parts.append("session expired")
        } else if case .failed(let badge) = state, badge == authFailureBadge {
            parts.append("session expired")
        }
        return parts.joined(separator: ", ")
    }

    private static func windowPercent(_ window: UsageWindow?) -> String {
        window.map { "\(Int($0.utilization))%" } ?? "no data"
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
