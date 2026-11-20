import Foundation

struct GrokAuth: Equatable {
    let accessToken: String
    let userID: String
    let email: String?
    let expiresAt: Date?

    static var defaultURL: URL {
        let home = ProcessInfo.processInfo.environment["GROK_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
        return home.appendingPathComponent("auth.json")
    }

    // Read-only: auth.json belongs to the Grok CLI and must never be refreshed here.
    static func load(from url: URL = defaultURL) -> GrokAuth? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let entries = root.values.compactMap { $0 as? [String: Any] }
        let entry = entries.first {
            ($0["oidc_issuer"] as? String)?.hasPrefix("https://auth.x.ai") == true
                && $0["key"] as? String != nil
        } ?? entries.first { $0["key"] as? String != nil }

        guard let entry,
              let key = entry["key"] as? String,
              let userID = entry["user_id"] as? String
        else { return nil }
        let expiresAt = (entry["expires_at"] as? String).flatMap(parseDate)
        return GrokAuth(accessToken: key, userID: userID,
                        email: entry["email"] as? String, expiresAt: expiresAt)
    }

    func isExpired(now: Date = .now) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        return ISO8601DateFormatter().date(from: value)
    }
}

struct GrokProvider {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func fetchUsage(auth: GrokAuth) async throws -> Usage {
        guard !auth.isExpired() else { throw FetchError.unauthorized }
        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue(auth.userID, forHTTPHeaderField: "x-userid")

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw FetchError.fromNetwork(error) }
        guard let http = response as? HTTPURLResponse else {
            throw FetchError.badResponse("non-HTTP response")
        }
        switch http.statusCode {
        case 200: return try GrokUsageParser.parse(data)
        case 401, 403: throw FetchError.unauthorized
        case 429: throw FetchError.rateLimited
        case let status: throw FetchError.badResponse("HTTP \(status)")
        }
    }
}
