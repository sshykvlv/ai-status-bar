import Foundation

enum GrokUsageParser {
    static func parse(_ data: Data) throws -> Usage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any]
        else { throw FetchError.badResponse("grok usage: no config") }

        let period = config["currentPeriod"] as? [String: Any]
        let periodType = period?["type"] as? String
        guard periodType == nil || periodType == "USAGE_PERIOD_TYPE_WEEKLY" else {
            return Usage(fiveHour: nil, sevenDay: nil)
        }
        guard let percent = ((config["creditUsagePercent"]
                              ?? config["credit_usage_percent"]) as? NSNumber)?.doubleValue else {
            return Usage(fiveHour: nil, sevenDay: nil)
        }
        let resetString = (period?["end"] as? String) ?? (config["billingPeriodEnd"] as? String)
        let reset = resetString.flatMap(parseDate)
        return Usage(fiveHour: nil,
                     sevenDay: UsageWindow(utilization: percent, resetsAt: reset))
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}
