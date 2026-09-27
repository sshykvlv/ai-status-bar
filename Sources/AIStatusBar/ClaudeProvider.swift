import Foundation

struct ClaudeProfile: Equatable {
    let email: String?
    let planLabel: String?
}

struct ClaudeProvider {
    static let userAgent = "claude-code/2.0.0"   // without this UA header the endpoint puts us in an aggressive 429 bucket
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    private func authedRequest(_ url: String, accessToken: String) -> URLRequest {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return req
    }

    func fetchUsage(accessToken: String) async throws -> Usage {
        let req = authedRequest("https://api.anthropic.com/api/oauth/usage", accessToken: accessToken)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw FetchError.fromNetwork(error) }
        guard let http = resp as? HTTPURLResponse else { throw FetchError.badResponse("non-HTTP response") }
        switch http.statusCode {
        case 200: return try ClaudeUsageParser.parse(data)
        case 401, 403: throw FetchError.unauthorized
        case 429: throw FetchError.rateLimited
        case let s: throw FetchError.badResponse("HTTP \(s)")
        }
    }

    func fetchProfile(accessToken: String) async throws -> ClaudeProfile {
        let req = authedRequest("https://api.anthropic.com/api/oauth/profile", accessToken: accessToken)
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw FetchError.fromNetwork(error) }
        guard let http = resp as? HTTPURLResponse else { throw FetchError.badResponse("non-HTTP response") }
        switch http.statusCode {
        case 200: return try Self.parseProfile(data)
        case 401, 403: throw FetchError.unauthorized
        case 429: throw FetchError.rateLimited
        case let s: throw FetchError.badResponse("HTTP \(s)")
        }
    }

    static func parseProfile(_ data: Data) throws -> ClaudeProfile {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchError.badResponse("claude profile: not a JSON object")
        }
        let account = root["account"] as? [String: Any]
        let email = account?["email"] as? String
        let org = root["organization"] as? [String: Any]
        let tier = org?["rate_limit_tier"] as? String
        return ClaudeProfile(email: email, planLabel: planLabel(forTier: tier))
    }

    private static func planLabel(forTier tier: String?) -> String? {
        guard let tier else { return nil }
        switch tier {
        case "default_claude_max_20x": return "Max 20x"
        case "default_claude_max_5x": return "Max 5x"
        default:
            let lower = tier.lowercased()
            if lower.contains("pro") { return "Pro" }
            if lower.contains("team") { return "Team" }
            return nil
        }
    }

    // Token refresh for Claude Code's own OAuth tokens — used by later tasks (Poller, OAuth flow), not exercised by this task's tests. Keep it; it's not dead code.
    func refresh(_ tokens: OAuthTokens) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: ClaudeOAuthConstants.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
            "client_id": ClaudeOAuthConstants.clientID,
        ])
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw FetchError.fromNetwork(error) }
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200,
              let d = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = d["access_token"] as? String,
              let expiresIn = (d["expires_in"] as? NSNumber)?.doubleValue
        else { throw FetchError.unauthorized }
        let refresh = d["refresh_token"] as? String ?? tokens.refreshToken
        return OAuthTokens(accessToken: access, refreshToken: refresh,
                           expiresAt: Date().addingTimeInterval(expiresIn))
    }
}

enum ClaudeOAuthConstants {
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"  // Claude Code's public OAuth client_id
    static let authorizeURL = "https://claude.ai/oauth/authorize"
    static let tokenURL = "https://console.anthropic.com/v1/oauth/token"
    static let redirectURI = "http://localhost:54545/callback"
    static let scopes = "org:create_api_key user:profile user:inference"
}
