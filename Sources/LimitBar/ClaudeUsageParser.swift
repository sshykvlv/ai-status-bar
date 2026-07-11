import Foundation

enum ClaudeUsageParser {
    static func parse(_ data: Data) throws -> Usage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badResponse("claude usage: not a JSON object")
        }
        return Usage(fiveHour: window(root["five_hour"]),
                     sevenDay: window(root["seven_day"]))
    }

    private static func window(_ any: Any?) -> UsageWindow? {
        guard let d = any as? [String: Any] else { return nil }
        let util = (d["utilization"] as? NSNumber)?.doubleValue ?? 0
        var resets: Date?
        if let s = d["resets_at"] as? String {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            resets = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        } else if let n = d["resets_at"] as? NSNumber {
            resets = Date(timeIntervalSince1970: n.doubleValue)
        }
        return UsageWindow(utilization: util, resetsAt: resets)
    }
}
