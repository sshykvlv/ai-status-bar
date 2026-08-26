import Foundation

// @unchecked Sendable: only ever touched from @MainActor contexts (AppDelegate, OAuthFlow) —
// never actually shared across threads, but the type isn't itself actor-isolated.
final class AccountStore: @unchecked Sendable {
    private let key = "accounts"
    private let dismissedKey = "dismissedBuiltins"
    private let defaults: UserDefaults
    private(set) var accounts: [Account] = []
    private(set) var dismissedBuiltins: Set<String> = []

    init(defaults: UserDefaults = .standard,
         hasClaudeMain: @escaping () -> Bool = { KeychainStore.claudeCodeTokens() != nil },
         hasCodex: @escaping () -> Bool = { CodexAuth.load() != nil }) {
        self.defaults = defaults
        // Демо-режим: фиксированные аккаунты, без чтения/записи defaults и Keychain.
        if MockData.enabled {
            accounts = MockData.accounts
            return
        }
        if let data = defaults.data(forKey: key),
           let list = try? JSONDecoder().decode([Account].self, from: data) {
            accounts = list
        }
        if let list = defaults.array(forKey: dismissedKey) as? [String] {
            dismissedBuiltins = Set(list)
        }
        discoverBuiltins(hasClaudeMain: hasClaudeMain(), hasCodex: hasCodex())
    }

    /// Автоподхват: основной Claude (если есть Keychain-запись) и Codex (если есть auth.json).
    /// Пропускает builtin-виды, которые владелец явно удалил (см. dismissedBuiltins) —
    /// иначе Remove для claudeMain/codex не «прилипал» бы: он бы возвращался на каждом запуске.
    private func discoverBuiltins(hasClaudeMain: Bool, hasCodex: Bool) {
        var changed = false
        if !accounts.contains(where: { $0.kind == .claudeMain && $0.claudeConfigDir == nil }),
           hasClaudeMain, !dismissedBuiltins.contains(AccountKind.claudeMain.rawValue) {
            accounts.insert(Account(id: UUID(), name: "Claude", kind: .claudeMain, email: nil), at: 0)
            changed = true
        }
        if !accounts.contains(where: { $0.kind == .codex }),
           hasCodex, !dismissedBuiltins.contains(AccountKind.codex.rawValue) {
            accounts.append(Account(id: UUID(), name: "Codex", kind: .codex, email: nil))
            changed = true
        }
        if changed { persist() }
    }

    func add(_ account: Account) { insertSorted(account); persist() }
    func rename(id: UUID, to name: String) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].name = name; persist()
    }
    func setEmail(id: UUID, _ email: String?, plan: String? = nil) {
        guard let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts[i].email = email
        if let plan { accounts[i].plan = plan }
        persist()
    }
    func migrateToOwned(id: UUID, kind: AccountKind, email: String?, plan: String? = nil) {
        guard kind.isOwned,
              let i = accounts.firstIndex(where: { $0.id == id }) else { return }
        let source = accounts[i]
        let wasBuiltinClaude = source.kind == .claudeMain && source.claudeConfigDir == nil
        let wasBuiltinCodex = source.kind == .codex && source.codexHome == nil
        if wasBuiltinClaude { dismissedBuiltins.insert(AccountKind.claudeMain.rawValue) }
        if wasBuiltinCodex { dismissedBuiltins.insert(AccountKind.codex.rawValue) }
        if wasBuiltinClaude || wasBuiltinCodex {
            defaults.set(Array(dismissedBuiltins), forKey: dismissedKey)
        }
        accounts[i].kind = kind
        accounts[i].email = email
        if let plan { accounts[i].plan = plan }
        accounts[i].codexHome = nil
        accounts[i].claudeConfigDir = nil
        persist()
    }
    func remove(id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        // Dismissal только для автоподхваченных builtin-ов (основной Claude без своего
        // claudeConfigDir и Codex без своего codexHome). Добавленный вручную CLI-профиль
        // (со своим claudeConfigDir/CODEX_HOME) просто удаляется — иначе его удаление
        // ошибочно скрыло бы и основной builtin того же kind.
        let isBuiltinClaudeMain = account.kind == .claudeMain && account.claudeConfigDir == nil
        let isBuiltinCodex = account.kind == .codex && account.codexHome == nil
        if isBuiltinClaudeMain || isBuiltinCodex {
            dismissedBuiltins.insert(account.kind.rawValue)
            defaults.set(Array(dismissedBuiltins), forKey: dismissedKey)
        }
        accounts.removeAll { $0.id == id }
        KeychainStore.deleteOwn(accountID: id)
        persist()
    }

    /// Codex всегда последним.
    private func insertSorted(_ account: Account) {
        if let codexIdx = accounts.firstIndex(where: { $0.kind.isCodex }), !account.kind.isCodex {
            accounts.insert(account, at: codexIdx)
        } else {
            accounts.append(account)
        }
    }

    private func persist() { defaults.set(try? JSONEncoder().encode(accounts), forKey: key) }
}
