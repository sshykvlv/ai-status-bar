import AppKit
import Foundation
import Network

/// Centralized copy of Codex's public desktop PKCE contract. Keeping every
/// upstream-sensitive value in one place makes drift visible and testable.
enum CodexOAuthConstants {
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let authorizeURL = "https://auth.openai.com/oauth/authorize"
    static let tokenURL = "https://auth.openai.com/oauth/token"
    static let callbackPort: UInt16 = 1455
    static let redirectURI = "http://localhost:\(callbackPort)/auth/callback"
    static let scopes = "openid profile email offline_access api.connectors.read api.connectors.invoke"
}

enum CodexOAuthRequest {
    static func authorizeURL(challenge: String, state: String,
                             redirectURI: String = CodexOAuthConstants.redirectURI) -> URL {
        var components = URLComponents(string: CodexOAuthConstants.authorizeURL)!
        components.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: CodexOAuthConstants.clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "scope", value: CodexOAuthConstants.scopes),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "state", value: state),
            .init(name: "originator", value: "codex_cli_rs"),
        ]
        return components.url!
    }

    static func parseCallback(requestLine: String) -> (code: String, state: String)? {
        guard let pathPart = requestLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: String(pathPart)),
              components.path == "/auth/callback",
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = components.queryItems?.first(where: { $0.name == "state" })?.value,
              !code.isEmpty, !state.isEmpty
        else { return nil }
        return (code, state)
    }

    static func authorizationCodeRequest(code: String, verifier: String,
                                         redirectURI: String = CodexOAuthConstants.redirectURI) -> URLRequest {
        var components = URLComponents()
        components.queryItems = [
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "code", value: code),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "client_id", value: CodexOAuthConstants.clientID),
            .init(name: "code_verifier", value: verifier),
        ]
        var request = URLRequest(url: URL(string: CodexOAuthConstants.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)
        return request
    }
}

enum CodexJWT {
    static func expiration(_ token: String) -> Date? {
        guard let value = payload(token)?["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: value.doubleValue)
    }

    static func email(_ token: String) -> String? {
        guard let payload = payload(token) else { return nil }
        if let email = payload["email"] as? String { return email }
        return (payload["https://api.openai.com/profile"] as? [String: Any])?["email"] as? String
    }

    static func plan(_ token: String) -> String? {
        guard let auth = payload(token)?["https://api.openai.com/auth"] as? [String: Any],
              let raw = auth["chatgpt_plan_type"] as? String else { return nil }
        switch raw.lowercased() {
        case "free": return "Free"
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        default: return raw
        }
    }

    private static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var encoded = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder > 0 { encoded += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

@MainActor
final class CodexOAuthFlow {
    static let shared = CodexOAuthFlow()

    private var listener: NWListener?
    private var verifier = ""
    private var state = ""

    func start(store: AccountStore, reloginID: UUID? = nil, onDone: @escaping () -> Void) {
        let pkce = PKCE.generate()
        verifier = pkce.verifier
        state = UUID().uuidString
        listener?.cancel()

        guard let listener = try? NWListener(using: .tcp,
                                             on: NWEndpoint.Port(rawValue: CodexOAuthConstants.callbackPort)!) else {
            presentError("Couldn't start the local sign-in listener. Port 1455 is already in use; close another Codex sign-in and try again.")
            return
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard let data,
                      let text = String(data: data, encoding: .utf8),
                      let line = text.split(separator: "\r\n").first,
                      let parsed = CodexOAuthRequest.parseCallback(requestLine: String(line))
                else { connection.cancel(); return }
                let html = "<html><body style='font-family:-apple-system;text-align:center;padding-top:20vh'>AI Status Bar connected. You can close this tab.</body></html>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.exchange(code: parsed.code, returnedState: parsed.state,
                                        store: store, reloginID: reloginID, onDone: onDone)
                    self.listener?.cancel()
                    self.listener = nil
                }
            }
        }
        listener.start(queue: .main)
        NSWorkspace.shared.open(CodexOAuthRequest.authorizeURL(challenge: pkce.challenge, state: state))
    }

    private func exchange(code: String, returnedState: String, store: AccountStore,
                          reloginID: UUID?, onDone: @escaping () -> Void) async {
        guard returnedState == state else {
            presentError("Sign-in didn't complete because the security check failed. Try again.")
            return
        }
        let tokens: OAuthTokens
        do {
            tokens = try await CodexProvider().exchangeAuthorizationCode(code: code, verifier: verifier)
        } catch {
            presentError("OpenAI couldn't finish sign-in. Check your connection and try again.")
            return
        }
        let identityToken = tokens.idToken ?? tokens.accessToken
        let email = CodexJWT.email(identityToken)
        let plan = CodexJWT.plan(identityToken)
        do {
            if let reloginID {
                try KeychainStore.saveOwn(tokens, accountID: reloginID)
                store.migrateToOwned(id: reloginID, kind: .codexOAuth, email: email, plan: plan)
            } else {
                let account = Account(id: UUID(), name: email ?? "Codex", kind: .codexOAuth,
                                      email: email, plan: plan)
                try KeychainStore.saveOwn(tokens, accountID: account.id)
                store.add(account)
            }
        } catch {
            presentError("Sign-in completed, but AI Status Bar couldn't save it to Keychain. Try again.")
            return
        }
        onDone()
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't add Codex account"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
