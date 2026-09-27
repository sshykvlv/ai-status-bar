import Foundation

enum CodexUsageParser {
    private struct ParsedWindow {
        let usage: UsageWindow
        let duration: TimeInterval?
    }

    static func parse(_ data: Data) throws -> Usage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = root["rate_limit"] as? [String: Any] else {
            throw FetchError.badResponse("codex usage: no rate_limit")
        }
        let primary = window(rl["primary_window"])
        let secondary = window(rl["secondary_window"])
        let windows = [primary, secondary].compactMap { $0 }
        let fiveHour = windows.first { $0.duration == 18_000 }?.usage
            ?? (primary?.duration == nil ? primary?.usage : nil)
        let sevenDay = windows.first { $0.duration == 604_800 }?.usage
            ?? (secondary?.duration == nil ? secondary?.usage : nil)
        return Usage(fiveHour: fiveHour, sevenDay: sevenDay)
    }

    private static func window(_ any: Any?) -> ParsedWindow? {
        guard let d = any as? [String: Any],
              let util = (d["used_percent"] as? NSNumber)?.doubleValue else { return nil }
        let resets = (d["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        let duration = (d["limit_window_seconds"] as? NSNumber)?.doubleValue
        return ParsedWindow(usage: UsageWindow(utilization: util, resetsAt: resets),
                            duration: duration)
    }
}
