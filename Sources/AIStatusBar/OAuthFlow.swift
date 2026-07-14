import AppKit
import CryptoKit
import Network

enum PKCE {
    static func generate() -> (verifier: String, challenge: String) {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URLEncoded()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded()
        return (verifier, challenge)
    }
}

extension Data {
    func base64URLEncoded() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// In-app OAuth PKCE flow for adding an additional Claude account (or re-authing an existing one).
/// Opens the system browser to claude.ai's authorize page, then catches the redirect on a local
/// loopback listener (matches Claude Code's own OAuth client behavior) and exchanges the code for
/// tokens. All failures degrade to a beep — never crashes the menu bar app.
@MainActor
final class OAuthFlow {
    static let shared = OAuthFlow()
    private var listener: NWListener?
    private var verifier = ""
    private var state = ""

    nonisolated static func parseCallback(requestLine: String) -> (code: String, state: String)? {
        guard let pathPart = requestLine.split(separator: " ").dropFirst().first,
              let comps = URLComponents(string: String(pathPart)),
              comps.path == "/callback",
              let code = comps.queryItems?.first(where: { $0.name == "code" })?.value,
              let st = comps.queryItems?.first(where: { $0.name == "state" })?.value
        else { return nil }
        return (code, st)
    }

    func start(store: AccountStore, reloginID: UUID? = nil, onDone: @escaping () -> Void) {
        let pkce = PKCE.generate()
        verifier = pkce.verifier
        state = UUID().uuidString
        startListener(store: store, reloginID: reloginID, onDone: onDone)

        var comps = URLComponents(string: ClaudeOAuthConstants.authorizeURL)!
        comps.queryItems = [
            .init(name: "code", value: "true"),
            .init(name: "client_id", value: ClaudeOAuthConstants.clientID),
            .init(name: "response_type", value: "code"),
            .init(name: "redirect_uri", value: ClaudeOAuthConstants.redirectURI),
            .init(name: "scope", value: ClaudeOAuthConstants.scopes),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
        ]
        NSWorkspace.shared.open(comps.url!)
    }

    private func startListener(store: AccountStore, reloginID: UUID?, onDone: @escaping () -> Void) {
        listener?.cancel()
        guard let l = try? NWListener(using: .tcp, on: 54545) else {
            presentError("Couldn't start the local sign-in listener — port 54545 is already in use. Quit any other AI Status Bar processes (check Activity Monitor) and try again.")
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard let data, let text = String(data: data, encoding: .utf8),
                      let line = text.split(separator: "\r\n").first,
                      let parsed = Self.parseCallback(requestLine: String(line))
                else { conn.cancel(); return }
                let html = "<html><body style='font-family:-apple-system;text-align:center;padding-top:20vh'>AI Status Bar connected. You can close this tab.</body></html>"
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    await self.exchange(code: parsed.code, returnedState: parsed.state,
                                        store: store, reloginID: reloginID, onDone: onDone)
                    self.listener?.cancel(); self.listener = nil
                }
            }
        }
        l.start(queue: .main)
    }

    private func exchange(code: String, returnedState: String, store: AccountStore,
                          reloginID: UUID?, onDone: @escaping () -> Void) async {
        guard returnedState == state else {
            presentError("Sign-in didn't complete — the security check failed (state mismatch). Please try again.")
            return
        }
        var req = URLRequest(url: URL(string: ClaudeOAuthConstants.tokenURL)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "authorization_code",
            "code": code,
            "state": returnedState,
            "client_id": ClaudeOAuthConstants.clientID,
            "redirect_uri": ClaudeOAuthConstants.redirectURI,
            "code_verifier": verifier,
        ])
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch {
            presentError("Couldn't reach Anthropic to finish sign-in: \(error.localizedDescription). Check your connection and try again.")
            return
        }
        guard let http = resp as? HTTPURLResponse else {
            presentError("Sign-in failed — Anthropic returned an unexpected response. Try again.")
            return
        }
        guard http.statusCode == 200 else {
            presentError("Sign-in failed — Anthropic rejected the request (HTTP \(http.statusCode)). Try Add Claude Account again.")
            return
        }
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = d["access_token"] as? String,
              let refresh = d["refresh_token"] as? String,
              let expiresIn = (d["expires_in"] as? NSNumber)?.doubleValue
        else {
            presentError("Sign-in succeeded but the token response was malformed. Try Add Claude Account again.")
            return
        }
        let tokens = OAuthTokens(accessToken: access, refreshToken: refresh,
                                 expiresAt: Date().addingTimeInterval(expiresIn))
        let email = (d["account"] as? [String: Any])?["email_address"] as? String
        do {
            if let reloginID {
                try KeychainStore.saveOwn(tokens, accountID: reloginID)
            } else {
                // Сохраняем токены ДО добавления аккаунта: если Keychain-запись
                // не удалась, аккаунт не появляется (иначе он завис бы с «re-login»).
                let account = Account(id: UUID(), name: email ?? "Claude 2",
                                      kind: .claudeOAuth, email: email)
                try KeychainStore.saveOwn(tokens, accountID: account.id)
                store.add(account)
            }
        } catch {
            presentError("Signed in, but saving the account to Keychain failed: \(error.localizedDescription). Try again.")
            return
        }
        onDone()
    }

    /// Every OAuthFlow failure surfaces here instead of a silent beep — a background
    /// menu bar app that only ever beeps on failure leaves the owner guessing why
    /// "Add Claude Account…" didn't work (HANDOFF issue #3).
    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't add Claude account"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
