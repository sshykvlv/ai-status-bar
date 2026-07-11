import Foundation
import Security

struct OAuthTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
}

enum KeychainStore {
    private static let ownService = "LimitBar"

    // MARK: чтение кредов Claude Code (read-only, ничего не пишем)
    static func claudeCodeTokens() -> OAuthTokens? {
        guard let data = read(service: "Claude Code-credentials", account: nil),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],   // может отсутствовать (CC 2.1.x гоча)
              let access = oauth["accessToken"] as? String,
              let refresh = oauth["refreshToken"] as? String,
              let expMs = (oauth["expiresAt"] as? NSNumber)?.doubleValue
        else { return nil }
        return OAuthTokens(accessToken: access, refreshToken: refresh,
                           expiresAt: Date(timeIntervalSince1970: expMs / 1000))
    }

    // MARK: свои токены (по аккаунту)
    static func saveOwn(_ tokens: OAuthTokens, accountID: UUID) throws {
        let data = try JSONEncoder().encode(tokens)
        deleteOwn(accountID: accountID)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: accountID.uuidString,
            kSecValueData as String: data,
        ]
        guard SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess else {
            throw FetchError.badResponse("keychain save failed")
        }
    }

    static func loadOwn(accountID: UUID) -> OAuthTokens? {
        guard let data = read(service: ownService, account: accountID.uuidString) else { return nil }
        return try? JSONDecoder().decode(OAuthTokens.self, from: data)
    }

    static func deleteOwn(accountID: UUID) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService,
            kSecAttrAccount as String: accountID.uuidString,
        ]
        SecItemDelete(q as CFDictionary)
    }

    private static func read(service: String, account: String?) -> Data? {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { q[kSecAttrAccount as String] = account }
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
}
