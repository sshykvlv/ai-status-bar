import Foundation

enum CodexUsageParser {
    static func parse(_ data: Data) throws -> Usage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rl = root["rate_limit"] as? [String: Any] else {
            throw FetchError.badResponse("codex usage: no rate_limit")
        }
        return Usage(fiveHour: window(rl["primary_window"]),
                     sevenDay: window(rl["secondary_window"]))
    }

    private static func window(_ any: Any?) -> UsageWindow? {
        guard let d = any as? [String: Any] else { return nil }
        let util = (d["used_percent"] as? NSNumber)?.doubleValue ?? 0
        let resets = (d["reset_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(utilization: util, resetsAt: resets)
    }
}
