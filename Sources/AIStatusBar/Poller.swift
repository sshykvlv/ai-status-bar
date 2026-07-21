import Foundation
import os

@MainActor
final class Poller {
    /// Was silent until 2026-07-20 — a real "opять логинится" complaint the next morning
    /// left zero trace anywhere (no app log at all, and system securityd/coreauthd logs
    /// had nothing for AIStatusBar either), so there was no way to tell a genuine denial
    /// from the dark-wake false-positive `pollAfterWake()` already guards against. Query
    /// with `log show --predicate 'subsystem == "lv.ykv.aistatusbar"' --info`.
    private static let log = Logger(subsystem: "lv.ykv.aistatusbar", category: "poller")

    nonisolated static let interval: TimeInterval = 60
    nonisolated static let backoffSchedule: [TimeInterval] = [120, 240, 480, 900]

    private let store: AccountStore
    private var states: [UUID: AccountState] = [:]
    private var backoffLevel: [UUID: Int] = [:]
    private var nextAllowed: [UUID: Date] = [:]
    private var authFailureLevel: [UUID: Int] = [:]
    /// Gate for `.unauthorized` retries — unlike `nextAllowed`, `force` polls (menu-open,
    /// wake) do NOT bypass this one. A Keychain read denial surfaces an interactive OS
    /// authorization dialog, not a silent failure; retrying it every 60s timer tick and on
    /// every menu-open flashed that dialog repeatedly (readable-for-tests to prove a forced
    /// poll during backoff didn't re-attempt).
    private(set) var authNextAllowed: [UUID: Date] = [:]
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

    /// Wake fires `didWakeNotification` mid dark-wake, before the lid is fully
    /// open — coreauthd cancels any in-flight biometric prompt ("Lid is closed")
    /// right as this poll tries to read the Keychain, so `SecItemCopyMatching`
    /// comes back denied (securityd: "user did not approve 'allow'") rather than
    /// "item not found". That reads identically to a real logout and flashes a
    /// false re-login badge on an account that was fine a second ago. Retrying
    /// once, only for accounts that just went from .ok to an auth failure, fixes
    /// the false flash without masking a genuine logout for more than ~2s.
    func pollAfterWake() {
        Self.log.notice("pollAfterWake fired")
        Task { await pollAll(force: true, retryUnauthorizedOnce: true) }
    }

    func state(for id: UUID) -> AccountState { states[id] ?? .pending }

    func pollAll(force: Bool, retryUnauthorizedOnce: Bool = false) async {
        // Демо-режим: фиксированные состояния вместо сети (см. MockData).
        if MockData.enabled {
            for account in store.accounts { states[account.id] = MockData.state(for: account.id) }
            onUpdate?(states)
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for account in store.accounts {
                group.addTask { @MainActor in
                    await self.poll(account, force: force, retryUnauthorizedOnce: retryUnauthorizedOnce)
                }
            }
        }
        onUpdate?(states)
    }

    private func poll(_ account: Account, force: Bool, retryUnauthorizedOnce: Bool = false) async {
        let now = Date()
        if let gate = nextAllowed[account.id], now < gate, !force { return }
        if let authGate = authNextAllowed[account.id], now < authGate {
            Self.log.debug("skip \(account.name, privacy: .public): auth backoff until \(authGate, privacy: .public)")
            return
        }
        if force, let last = lastFetch(account.id), now.timeIntervalSince(last) < 10 { return }
        nextAllowed[account.id] = now.addingTimeInterval(Self.interval - 1)
        do {
            let fetched = try await fetchUsage(for: account)
            if authFailureLevel[account.id] != nil {
                Self.log.notice("recovered \(account.name, privacy: .public) after auth failure")
            }
            backoffLevel[account.id] = nil
            authFailureLevel[account.id] = nil
            authNextAllowed[account.id] = nil
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
            if retryUnauthorizedOnce, case .ok = states[account.id] ?? .pending {
                Self.log.notice("unauthorized \(account.name, privacy: .public) right after wake, was .ok — retrying once in 2s (dark-wake guard)")
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await poll(account, force: true, retryUnauthorizedOnce: false)
                return
            }
            let lvl = min((authFailureLevel[account.id] ?? -1) + 1, Self.backoffSchedule.count - 1)
            authFailureLevel[account.id] = lvl
            let until = Date().addingTimeInterval(Self.backoffSchedule[lvl])
            authNextAllowed[account.id] = until
            Self.log.error("unauthorized \(account.name, privacy: .public) kind=\(account.kind.rawValue, privacy: .public) level=\(lvl, privacy: .public) backoffUntil=\(until, privacy: .public)")
            demote(account.id, badge: badgeForAuthFailure(account))
        } catch {
            Self.log.error("offline \(account.name, privacy: .public): \(String(describing: error), privacy: .public)")
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
