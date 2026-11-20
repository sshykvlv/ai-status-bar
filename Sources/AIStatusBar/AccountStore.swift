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
         hasCodex: @escaping () -> Bool = { CodexAuth.load() != nil },
         hasGrok: @escaping () -> Bool = { GrokAuth.load() != nil }) {
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
        discoverBuiltins(hasClaudeMain: hasClaudeMain(), hasCodex: hasCodex(), hasGrok: hasGrok())
    }

    /// Автоподхват: основной Claude (если есть Keychain-запись), Codex и Grok (если есть auth.json).
    /// Пропускает builtin-виды, которые владелец явно удалил (см. dismissedBuiltins) —
    /// иначе Remove для builtin-строки не «прилипал» бы: она возвращалась бы на каждом запуске.
    private func discoverBuiltins(hasClaudeMain: Bool, hasCodex: Bool, hasGrok: Bool) {
        var changed = false
        if !accounts.contains(where: { $0.kind == .claudeMain && $0.claudeConfigDir == nil }),
           hasClaudeMain, !dismissedBuiltins.contains(AccountKind.claudeMain.rawValue) {
            accounts.insert(Account(id: UUID(), name: "Claude", kind: .claudeMain, email: nil), at: 0)
            changed = true
        }
        if !accounts.contains(where: { $0.kind == .codex }),
           hasCodex, !dismissedBuiltins.contains(AccountKind.codex.rawValue) {
            insertSorted(Account(id: UUID(), name: "Codex", kind: .codex, email: nil))
            changed = true
        }
        if !accounts.contains(where: { $0.kind == .grok }),
           hasGrok, !dismissedBuiltins.contains(AccountKind.grok.rawValue) {
            accounts.append(Account(id: UUID(), name: "Grok", kind: .grok, email: nil))
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
        if let email { accounts[i].email = email }
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
        let isBuiltinGrok = account.kind == .grok
        if isBuiltinClaudeMain || isBuiltinCodex || isBuiltinGrok {
            dismissedBuiltins.insert(account.kind.rawValue)
            defaults.set(Array(dismissedBuiltins), forKey: dismissedKey)
        }
        accounts.removeAll { $0.id == id }
        KeychainStore.deleteOwn(accountID: id)
        persist()
    }

    /// Grok всегда последним; Codex остаётся после Claude-аккаунтов.
    private func insertSorted(_ account: Account) {
        if account.kind == .grok { accounts.append(account); return }
        if account.kind.isCodex {
            accounts.insert(account, at: accounts.firstIndex(where: { $0.kind == .grok }) ?? accounts.endIndex)
            return
        }
        accounts.insert(account, at: accounts.firstIndex(where: { $0.kind.isCodex || $0.kind == .grok })
                        ?? accounts.endIndex)
    }

    private func persist() { defaults.set(try? JSONEncoder().encode(accounts), forKey: key) }
}
