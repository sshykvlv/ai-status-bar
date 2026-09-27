import Foundation

struct CodexAuth: Equatable {
    let accessToken: String
    let refreshToken: String
    let idToken: String?

    static var defaultURL: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            .map(URL.init(fileURLWithPath:))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return home.appendingPathComponent("auth.json")
    }

    /// Загрузка из конкретного CODEX_HOME (папки с auth.json) — для доп. Codex-аккаунтов.
    static func load(homePath: String) -> CodexAuth? {
        load(from: URL(fileURLWithPath: homePath, isDirectory: true).appendingPathComponent("auth.json"))
    }

    /// Путь к CODEX_HOME по умолчанию (родитель defaultURL) — для дедупа при добавлении.
    static var defaultHomePath: String { defaultURL.deletingLastPathComponent().path }

    // Read-only: never write auth.json back — it belongs to the codex CLI.
    static func load(from url: URL = defaultURL) -> CodexAuth? {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String,
              let refresh = tokens["refresh_token"] as? String
        else { return nil }
        return CodexAuth(accessToken: access, refreshToken: refresh, idToken: tokens["id_token"] as? String)
    }

    /// Decodes the `email` claim from the id_token JWT payload. Pure/offline — no network.
    func email() -> String? {
        idToken.flatMap(CodexJWT.email)
    }
}

struct CodexProvider {
    let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func fetchUsage(accessToken: String) async throws -> Usage {
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: req) }
        catch { throw FetchError.fromNetwork(error) }
        guard let http = resp as? HTTPURLResponse else { throw FetchError.badResponse("non-HTTP response") }
        switch http.statusCode {
        case 200: return try CodexUsageParser.parse(data)
        case 401, 403: throw FetchError.unauthorized
        case 429: throw FetchError.rateLimited
        case let s: throw FetchError.badResponse("HTTP \(s)")
        }
    }

    func exchangeAuthorizationCode(code: String, verifier: String,
                                   redirectURI: String = CodexOAuthConstants.redirectURI,
                                   now: Date = .now) async throws -> OAuthTokens {
        let request = CodexOAuthRequest.authorizationCodeRequest(
            code: code, verifier: verifier, redirectURI: redirectURI)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) }
        catch { throw FetchError.fromNetwork(error) }
        guard let http = response as? HTTPURLResponse else { throw FetchError.unauthorized }
        guard http.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = body["access_token"] as? String,
              let refresh = body["refresh_token"] as? String,
              let idToken = body["id_token"] as? String
        else { throw FetchError.unauthorized }
        return OAuthTokens(accessToken: access, refreshToken: refresh,
                           expiresAt: CodexJWT.expiration(access) ?? now.addingTimeInterval(3600),
                           idToken: idToken)
    }

    func refresh(_ tokens: OAuthTokens, now: Date = .now) async throws -> OAuthTokens {
        var req = URLRequest(url: URL(string: CodexOAuthConstants.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_id": CodexOAuthConstants.clientID,
            "grant_type": "refresh_token",
            "refresh_token": tokens.refreshToken,
        ])
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: req) }
        catch { throw FetchError.fromNetwork(error) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw FetchError.unauthorized }
        let access = body["access_token"] as? String ?? tokens.accessToken
        return OAuthTokens(
            accessToken: access,
            refreshToken: body["refresh_token"] as? String ?? tokens.refreshToken,
            expiresAt: CodexJWT.expiration(access)
                ?? (access == tokens.accessToken ? tokens.expiresAt : now.addingTimeInterval(3600)),
            idToken: body["id_token"] as? String ?? tokens.idToken)
    }
}
