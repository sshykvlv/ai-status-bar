import XCTest
@testable import AIStatusBar

final class PollerTests: XCTestCase {
    func testBackoffScheduleShape() {
        XCTAssertEqual(Poller.backoffSchedule, [120, 240, 480, 900])
        XCTAssertEqual(Poller.interval, 60)
    }

    func testWorstUtilizationTakesMax() {
        let u = Usage(fiveHour: .init(utilization: 30, resetsAt: nil),
                      sevenDay: .init(utilization: 80, resetsAt: nil))
        XCTAssertEqual(u.worstUtilization, 80)
    }

    // menuWillOpen calls pollNow() (force: true) on every single menu open, and the
    // 60s timer does the same on every tick. For a Keychain-backed account (claudeMain/
    // claudeOAuth) an .unauthorized failure means SecItemCopyMatching came back denied —
    // retrying that on every forced poll re-surfaces the interactive macOS "wants to
    // access key ... in your keychain" dialog again and again, which is exactly what
    // "оно опять логинится" reports. A claudeMain account pointed at a bogus
    // claudeConfigDir reproduces .unauthorized deterministically with no real Keychain
    // prompt or network call: KeychainStore.claudeCodeService hashes the given path into
    // a service name that matches no real Keychain item (unlike CodexAuth.load, which
    // falls back to the real default ~/.codex when the given home has no auth.json —
    // that fallback made a .codex-based version of this test silently hit this
    // machine's real, logged-in Codex account instead of failing).
    @MainActor
    func testUnauthorizedAccountBacksOffAcrossForcedPolls() async {
        let store = AccountStore(defaults: UserDefaults(suiteName: "aistatusbar.test.\(UUID().uuidString)")!,
                                 hasClaudeMain: { false }, hasCodex: { false })
        let id = UUID()
        store.add(Account(id: id, name: "Test Claude", kind: .claudeMain, email: nil,
                          claudeConfigDir: "/tmp/aistatusbar-test-nonexistent-\(UUID().uuidString)"))

        let poller = Poller(store: store)
        await poller.pollAll(force: true)
        guard case .failed = poller.state(for: id) else {
            return XCTFail("expected .failed after the first unauthorized poll")
        }
        let gateAfterFirst = try? XCTUnwrap(poller.authNextAllowed[id])
        XCTAssertNotNil(gateAfterFirst, "an unauthorized failure must set a backoff gate")

        // Simulates exactly what menuWillOpen does on every open: another forced poll,
        // immediately. Within the backoff window this must NOT re-attempt the fetch —
        // otherwise every menu-open would flash the Keychain dialog again.
        await poller.pollAll(force: true)
        XCTAssertEqual(poller.authNextAllowed[id], gateAfterFirst,
                       "a forced poll inside the backoff window re-attempted the fetch instead of being gated")
    }
}

final class AccountStoreTests: XCTestCase {
    private func ephemeralDefaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "aistatusbar.test.\(UUID().uuidString)")!
        return d
    }

    func testDiscoversNoBuiltinsWhenAbsent() {
        let store = AccountStore(defaults: ephemeralDefaults(),
                                 hasClaudeMain: { false }, hasCodex: { false })
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testDiscoversClaudeMainAndCodex() {
        let store = AccountStore(defaults: ephemeralDefaults(),
                                 hasClaudeMain: { true }, hasCodex: { true })
        XCTAssertEqual(store.accounts.first?.kind, .claudeMain)
        XCTAssertEqual(store.accounts.last?.kind, .codex)
    }

    func testAddKeepsCodexLast() {
        let store = AccountStore(defaults: ephemeralDefaults(),
                                 hasClaudeMain: { false }, hasCodex: { true })
        store.add(Account(id: UUID(), name: "Claude 2", kind: .claudeOAuth, email: nil))
        XCTAssertEqual(store.accounts.last?.kind, .codex)
        XCTAssertEqual(store.accounts.first?.kind, .claudeOAuth)
    }

    func testPersistenceRoundtrip() {
        let d = ephemeralDefaults()
        let store1 = AccountStore(defaults: d, hasClaudeMain: { false }, hasCodex: { false })
        let id = UUID()
        store1.add(Account(id: id, name: "Extra", kind: .claudeOAuth, email: "a@b.c"))
        let store2 = AccountStore(defaults: d, hasClaudeMain: { false }, hasCodex: { false })
        XCTAssertEqual(store2.accounts.first(where: { $0.id == id })?.name, "Extra")
    }

    func testMigratingBuiltinCodexPreservesRowAndPreventsRediscovery() throws {
        let defaults = ephemeralDefaults()
        let store = AccountStore(defaults: defaults, hasClaudeMain: { true }, hasCodex: { true })
        let original = try XCTUnwrap(store.accounts.first(where: { $0.kind == .codex }))
        let originalIndex = try XCTUnwrap(store.accounts.firstIndex(where: { $0.id == original.id }))

        store.migrateToOwned(id: original.id, kind: .codexOAuth,
                             email: "sasha@ykv.lv", plan: "Pro")

        let migrated = try XCTUnwrap(store.accounts.first(where: { $0.id == original.id }))
        XCTAssertEqual(migrated.name, original.name)
        XCTAssertEqual(migrated.kind, .codexOAuth)
        XCTAssertEqual(migrated.email, "sasha@ykv.lv")
        XCTAssertEqual(migrated.plan, "Pro")
        XCTAssertNil(migrated.codexHome)
        XCTAssertEqual(store.accounts.firstIndex(where: { $0.id == original.id }), originalIndex)
        XCTAssertTrue(store.dismissedBuiltins.contains(AccountKind.codex.rawValue))

        let restarted = AccountStore(defaults: defaults, hasClaudeMain: { true }, hasCodex: { true })
        XCTAssertEqual(restarted.accounts.filter { $0.kind == .codexOAuth }.count, 1)
        XCTAssertFalse(restarted.accounts.contains { $0.kind == .codex })
    }

    func testMigratingBuiltinClaudePreservesRowAndPreventsRediscovery() throws {
        let defaults = ephemeralDefaults()
        let store = AccountStore(defaults: defaults, hasClaudeMain: { true }, hasCodex: { false })
        let original = try XCTUnwrap(store.accounts.first)

        store.migrateToOwned(id: original.id, kind: .claudeOAuth,
                             email: "sasha@ykv.lv", plan: "Max")

        let migrated = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(migrated.id, original.id)
        XCTAssertEqual(migrated.name, original.name)
        XCTAssertEqual(migrated.kind, .claudeOAuth)
        XCTAssertNil(migrated.claudeConfigDir)
        XCTAssertTrue(store.dismissedBuiltins.contains(AccountKind.claudeMain.rawValue))

        let restarted = AccountStore(defaults: defaults, hasClaudeMain: { true }, hasCodex: { false })
        XCTAssertEqual(restarted.accounts.map(\.kind), [.claudeOAuth])
    }

    func testReconnectWithoutReturnedIdentityKeepsKnownIdentity() throws {
        let store = AccountStore(defaults: ephemeralDefaults(),
                                 hasClaudeMain: { false }, hasCodex: { false })
        let id = UUID()
        store.add(Account(id: id, name: "Work", kind: .codex,
                          email: "known@ykv.lv", plan: "Pro",
                          codexHome: "/tmp/work-codex"))

        store.migrateToOwned(id: id, kind: .codexOAuth, email: nil, plan: nil)

        let migrated = try XCTUnwrap(store.accounts.first)
        XCTAssertEqual(migrated.email, "known@ykv.lv")
        XCTAssertEqual(migrated.plan, "Pro")
    }

    func testRenameAndRemove() {
        let store = AccountStore(defaults: ephemeralDefaults(),
                                 hasClaudeMain: { false }, hasCodex: { false })
        let id = UUID()
        store.add(Account(id: id, name: "Old", kind: .claudeOAuth, email: nil))
        store.rename(id: id, to: "New")
        XCTAssertEqual(store.accounts.first?.name, "New")
        store.remove(id: id)
        XCTAssertTrue(store.accounts.isEmpty)
    }

    func testSetEmailPersistsEmailAndPlan() {
        let store = AccountStore(defaults: ephemeralDefaults(),
                                 hasClaudeMain: { false }, hasCodex: { false })
        let id = UUID()
        store.add(Account(id: id, name: "Claude", kind: .claudeMain, email: nil))
        store.setEmail(id: id, "sasha@ykv.lv", plan: "Max 20x")
        XCTAssertEqual(store.accounts.first?.email, "sasha@ykv.lv")
        XCTAssertEqual(store.accounts.first?.plan, "Max 20x")
    }

    func testRemovingBuiltinDismissesItPermanently() throws {
        let defaults = ephemeralDefaults()
        let store1 = AccountStore(defaults: defaults, hasClaudeMain: { true }, hasCodex: { false })
        let id = try XCTUnwrap(store1.accounts.first(where: { $0.kind == .claudeMain })?.id)
        store1.remove(id: id)
        XCTAssertTrue(store1.accounts.isEmpty)
        // Restart with the same "builtin present" signal — dismissal must stick.
        let store2 = AccountStore(defaults: defaults, hasClaudeMain: { true }, hasCodex: { false })
        XCTAssertFalse(store2.accounts.contains { $0.kind == .claudeMain })
    }

    // Removing a manually-added Codex account (one with its own codexHome) must NOT
    // dismiss the auto-detected builtin Codex — only the builtin (codexHome == nil) does.
    func testRemovingAddedCodexDoesNotDismissBuiltin() throws {
        let defaults = ephemeralDefaults()
        let store = AccountStore(defaults: defaults, hasClaudeMain: { false }, hasCodex: { true })
        let addedID = UUID()
        store.add(Account(id: addedID, name: "Work", kind: .codex, email: nil,
                          codexHome: "/tmp/second-codex-home"))
        store.remove(id: addedID)
        XCTAssertFalse(store.dismissedBuiltins.contains(AccountKind.codex.rawValue))
        // Builtin codex is still present after a restart.
        let store2 = AccountStore(defaults: defaults, hasClaudeMain: { false }, hasCodex: { true })
        XCTAssertTrue(store2.accounts.contains { $0.kind == .codex && $0.codexHome == nil })
    }

    // Removing a manually-added Claude CLI profile (its own claudeConfigDir) must NOT
    // dismiss the auto-detected builtin claudeMain — only the builtin (configDir == nil) does.
    func testRemovingAddedClaudeCLIProfileDoesNotDismissBuiltin() throws {
        let defaults = ephemeralDefaults()
        let store = AccountStore(defaults: defaults, hasClaudeMain: { false }, hasCodex: { false })
        let addedID = UUID()
        store.add(Account(id: addedID, name: "Claude 2", kind: .claudeMain, email: nil,
                          claudeConfigDir: "/tmp/second-claude-home"))
        store.remove(id: addedID)
        XCTAssertFalse(store.dismissedBuiltins.contains(AccountKind.claudeMain.rawValue))
        // Builtin claudeMain is still discoverable after a restart.
        let store2 = AccountStore(defaults: defaults, hasClaudeMain: { true }, hasCodex: { false })
        XCTAssertTrue(store2.accounts.contains { $0.kind == .claudeMain && $0.claudeConfigDir == nil })
    }

    // A manually-added Claude CLI profile must coexist with the auto-detected default
    // builtin — a CLAUDE_CONFIG_DIR profile is a *different* Keychain entry, not a
    // substitute for the default ~/.claude one.
    func testBuiltinClaudeMainCoexistsWithCLIProfile() {
        let defaults = ephemeralDefaults()
        let store = AccountStore(defaults: defaults, hasClaudeMain: { false }, hasCodex: { false })
        store.add(Account(id: UUID(), name: "Claude 2", kind: .claudeMain, email: nil,
                          claudeConfigDir: "/tmp/second-claude-home"))
        // Restart with the default builtin now present too.
        let store2 = AccountStore(defaults: defaults, hasClaudeMain: { true }, hasCodex: { false })
        XCTAssertTrue(store2.accounts.contains { $0.kind == .claudeMain && $0.claudeConfigDir == nil })
        XCTAssertTrue(store2.accounts.contains { $0.claudeConfigDir == "/tmp/second-claude-home" })
    }
}
