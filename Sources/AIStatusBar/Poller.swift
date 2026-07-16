import Foundation

@MainActor
final class Poller {
    nonisolated static let interval: TimeInterval = 60
    nonisolated static let backoffSchedule: [TimeInterval] = [120, 240, 480, 900]

    private let store: AccountStore
    private var states: [UUID: AccountState] = [:]
    private var backoffLevel: [UUID: Int] = [:]
    private var nextAllowed: [UUID: Date] = [:]
    private var timer: Timer?
    var onUpdate: (([UUID: AccountState]) -> Void)?
    let alertEngine = AlertEngine()
    var onAlerts: (([AlertEvent]) -> Void)?
    private let burnRateEstimator = BurnRateEstimator()

    private var codexAccessOverride: [UUID: String] = [:]   // refreshed token per codex account
    private var ownTokens: [UUID: OAuthTokens] = [:]
    private var identityAttempted: Set<UUID> = []

    init(store: AccountStore) { self.store = store }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.pollAll(force: false) }
        }
        Task { await pollAll(force: false) }
    }

    func pollNow() { Task { await pollAll(force: true) } }

    func state(for id: UUID) -> AccountState { states[id] ?? .pending }

    private func pollAll(force: Bool) async {
        // Демо-режим: фиксированные состояния вместо сети (см. MockData).
        if MockData.enabled {
            for account in store.accounts { states[account.id] = MockData.state(for: account.id) }
            onUpdate?(states)
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for account in store.accounts {
                group.addTask { @MainActor in await self.poll(account, force: force) }
            }
        }
        onUpdate?(states)
    }

    private func poll(_ account: Account, force: Bool) async {
        let now = Date()
        if let gate = nextAllowed[account.id], now < gate, !force { return }
        if force, let last = lastFetch(account.id), now.timeIntervalSince(last) < 10 { return }
        nextAllowed[account.id] = now.addingTimeInterval(Self.interval - 1)
        do {
            let fetched = try await fetchUsage(for: account)
            backoffLevel[account.id] = nil
            let usage = withBurnRateForecast(account: account, usage: fetched)
            states[account.id] = .ok(usage, fetchedAt: Date())
            // Движок всегда обрабатывает опрос (чтобы состояние прогревалось даже пока
            // алерты выключены) — гейт "включено ли" живёт в AppDelegate, не здесь.
            let events = alertEngine.process(accountID: account.id, accountName: account.name, usage: usage)
            if !events.isEmpty { onAlerts?(events) }
            await fetchIdentityIfNeeded(account)
        } catch FetchError.rateLimited {
            let lvl = min((backoffLevel[account.id] ?? -1) + 1, Self.backoffSchedule.count - 1)
            backoffLevel[account.id] = lvl
            nextAllowed[account.id] = Date().addingTimeInterval(Self.backoffSchedule[lvl])
            demote(account.id, badge: "rate-limited")
        } catch FetchError.unauthorized {
            demote(account.id, badge: badgeForAuthFailure(account))
        } catch {
            demote(account.id, badge: "offline")
        }
    }

    private func fetchUsage(for account: Account) async throws -> Usage {
        switch account.kind {
        case .claudeMain:
            guard let t = KeychainStore.claudeCodeTokens(configDir: account.claudeConfigDir) else {
                throw FetchError.unauthorized
            }
            return try await ClaudeProvider().fetchUsage(accessToken: t.accessToken)
        case .claudeOAuth:
            guard var t = ownTokens[account.id] ?? KeychainStore.loadOwn(accountID: account.id) else {
                throw FetchError.unauthorized
            }
            if t.expiresAt < Date().addingTimeInterval(300) {
                t = try await ClaudeProvider().refresh(t)
                try? KeychainStore.saveOwn(t, accountID: account.id)
            }
            ownTokens[account.id] = t
            return try await ClaudeProvider().fetchUsage(accessToken: t.accessToken)
        case .codex:
            let loaded = account.codexHome.flatMap { CodexAuth.load(homePath: $0) } ?? CodexAuth.load()
            guard let auth = loaded else { throw FetchError.unauthorized }
            do {
                return try await CodexProvider().fetchUsage(accessToken: codexAccessOverride[account.id] ?? auth.accessToken)
            } catch FetchError.unauthorized {
                let fresh = try await CodexProvider().refresh(auth)
                codexAccessOverride[account.id] = fresh
                return try await CodexProvider().fetchUsage(accessToken: fresh)
            }
        }
    }

    /// Прогоняет свежие utilization-сэмплы через BurnRateEstimator и, если прогноз
    /// исчерпания наступает раньше resetsAt окна, заполняет им projectedExhaustion.
    /// Без resetsAt прогноз не показываем — не с чем сравнить, "врезаться" не во что.
    private func withBurnRateForecast(account: Account, usage: Usage) -> Usage {
        let now = Date()
        func forecast(_ window: UsageWindow?, keySuffix: String) -> UsageWindow? {
            guard let window else { return nil }
            let key = "\(account.id):\(keySuffix)"
            burnRateEstimator.record(key: key, utilization: window.utilization, at: now)
            guard let resetsAt = window.resetsAt,
                  let projected = burnRateEstimator.projectedExhaustion(key: key, now: now),
                  projected < resetsAt else {
                return window
            }
            return UsageWindow(utilization: window.utilization, resetsAt: window.resetsAt,
                                projectedExhaustion: projected)
        }
        return Usage(fiveHour: forecast(usage.fiveHour, keySuffix: "5h"),
                     sevenDay: forecast(usage.sevenDay, keySuffix: "7d"))
    }

    /// Fetches an account's identity (email + plan) once per app launch and caches
    /// it via the store. Never on every poll — an attempt is remembered for the
    /// lifetime of this Poller so we don't spam the profile endpoint or Keychain.
    /// Re-verifies even when `account.email` is already cached from a previous
    /// launch: a claudeConfigDir/CODEX_HOME's underlying credential can get
    /// silently re-logged into a different Anthropic account between launches
    /// (this owner's two-CLI-profile setup has done that more than once), and a
    /// stale cached email would otherwise keep showing the wrong identity for
    /// that row indefinitely.
    private func fetchIdentityIfNeeded(_ account: Account) async {
        guard !identityAttempted.contains(account.id) else { return }
        identityAttempted.insert(account.id)
        switch account.kind {
        case .claudeMain:
            guard let t = KeychainStore.claudeCodeTokens(configDir: account.claudeConfigDir) else { return }
            if let profile = try? await ClaudeProvider().fetchProfile(accessToken: t.accessToken) {
                store.setEmail(id: account.id, profile.email, plan: profile.planLabel)
            }
        case .claudeOAuth:
            guard let t = ownTokens[account.id] ?? KeychainStore.loadOwn(accountID: account.id) else { return }
            if let profile = try? await ClaudeProvider().fetchProfile(accessToken: t.accessToken) {
                store.setEmail(id: account.id, profile.email, plan: profile.planLabel)
            }
        case .codex:
            let auth = account.codexHome.flatMap { CodexAuth.load(homePath: $0) } ?? CodexAuth.load()
            if let email = auth?.email() {
                store.setEmail(id: account.id, email)
            }
        }
    }

    private func badgeForAuthFailure(_ account: Account) -> String {
        switch account.kind {
        case .claudeMain: return account.claudeConfigDir == nil ? "open Claude Code" : "re-login CLI profile"
        case .claudeOAuth: return "re-login"
        case .codex: return "run codex login"
        }
    }

    private func demote(_ id: UUID, badge: String) {
        if case let .ok(usage, at) = states[id] { states[id] = .stale(usage, fetchedAt: at, badge: badge) }
        else if case let .stale(usage, at, _) = states[id] { states[id] = .stale(usage, fetchedAt: at, badge: badge) }
        else { states[id] = .failed(badge: badge) }
    }

    private func lastFetch(_ id: UUID) -> Date? {
        switch states[id] {
        case .ok(_, let at), .stale(_, let at, _): return at
        default: return nil
        }
    }
}
