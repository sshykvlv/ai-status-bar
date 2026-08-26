# Unified Account UX Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan.

**Goal:** Make Claude and Codex accounts browser-added, app-owned, self-refreshing, and recoverable from one consistent menu flow without affecting CLI sessions.

**Architecture:** Keep legacy readers as a nondestructive compatibility layer, add explicit app-owned provider kinds, and centralize owned tokens in the existing Keychain service. Provider-specific OAuth clients produce the same `OAuthTokens` model; `Poller` proactively refreshes only app-owned credentials. `AccountStore` performs in-place soft migration so UI identity and ordering remain stable.

**Tech Stack:** Swift 5.9, AppKit, SwiftUI, Network, CryptoKit, Security, URLSession, XCTest

**Spec:** `docs/superpowers/specs/2026-08-26-unified-account-ux.md`

---

### Task 1: Model app-owned Codex sessions and soft migration

**Files:**
- Modify: `Sources/AIStatusBar/Models.swift`
- Modify: `Sources/AIStatusBar/AccountStore.swift`
- Modify: `Sources/AIStatusBar/KeychainStore.swift`
- Modify: `Tests/AIStatusBarTests/PollerTests.swift`
- Modify: `Tests/AIStatusBarTests/OAuthTests.swift`

**Step 1: Write failing model and migration tests**

Add tests proving that old `OAuthTokens` JSON still decodes, new optional ID-token data round-trips, and migrating a builtin account preserves ID/name/order while changing its kind and preventing rediscovery.

Run: `swift test --filter 'OAuthTests|AccountStoreTests'`
Expected: FAIL because `codexOAuth`, optional ID tokens, and `migrateToOwned` do not exist.

**Step 2: Implement the smallest compatible model change**

Add `AccountKind.codexOAuth`, make `Account.kind` mutable, add optional `idToken`, and add `AccountStore.migrateToOwned(id:kind:email:plan:)`. Clear legacy source paths and dismiss only the converted builtin source.

**Step 3: Verify and commit**

Run: `swift test --filter 'OAuthTests|AccountStoreTests'`
Expected: PASS.

Commit: `git add Sources/AIStatusBar/Models.swift Sources/AIStatusBar/AccountStore.swift Sources/AIStatusBar/KeychainStore.swift Tests/AIStatusBarTests/OAuthTests.swift Tests/AIStatusBarTests/PollerTests.swift && git commit -m "feat: model app-owned provider sessions"`

### Task 2: Add testable Codex browser OAuth and durable refresh rotation

**Files:**
- Create: `Sources/AIStatusBar/CodexOAuthFlow.swift`
- Modify: `Sources/AIStatusBar/CodexProvider.swift`
- Modify: `Sources/AIStatusBar/Poller.swift`
- Modify: `Tests/AIStatusBarTests/OAuthTests.swift`
- Modify: `Tests/AIStatusBarTests/ProviderTests.swift`

**Step 1: Write failing protocol tests**

Test the authorize URL, callback path/state parsing, form-encoded authorization-code exchange, token-response decoding, JWT expiry/email extraction, and refresh merging when OpenAI rotates only some returned tokens.

Run: `swift test --filter 'OAuthTests|ProviderTests'`
Expected: FAIL because the Codex OAuth request builders and refresh-token merge do not exist.

**Step 2: Implement OAuth and refresh**

Implement PKCE browser sign-in on the Codex loopback callback, exchange the code with `application/x-www-form-urlencoded`, save tokens before adding/migrating an account, and surface provider-specific `NSAlert` errors. For `.codexOAuth`, refresh five minutes before expiry and persist access, refresh, and ID token rotations. For legacy `.codex`, read usage only and never invoke the refresh endpoint.

**Step 3: Verify and commit**

Run: `swift test --filter 'OAuthTests|ProviderTests|PollerTests'`
Expected: PASS.

Commit: `git add Sources/AIStatusBar/CodexOAuthFlow.swift Sources/AIStatusBar/CodexProvider.swift Sources/AIStatusBar/Poller.swift Tests/AIStatusBarTests/OAuthTests.swift Tests/AIStatusBarTests/ProviderTests.swift Tests/AIStatusBarTests/PollerTests.swift && git commit -m "feat: own and refresh Codex browser sessions"`

### Task 3: Unify add and reconnect actions

**Files:**
- Modify: `Sources/AIStatusBar/OAuthFlow.swift`
- Modify: `Sources/AIStatusBar/main.swift`
- Modify: `Tests/AIStatusBarTests/OAuthTests.swift`
- Create: `Tests/AIStatusBarTests/AccountActionsTests.swift`

**Step 1: Write failing action-policy tests**

Extract and test a pure account-action policy: every account can sign in again; Claude sources route to Claude OAuth; Codex sources route to Codex OAuth; successful reconnect preserves the selected row.

Run: `swift test --filter 'OAuthTests|AccountActionsTests'`
Expected: FAIL because the unified provider routing does not exist.

**Step 2: Implement the approved flow**

Replace all three add actions with `Add Account…`, present Claude/Codex/Cancel with the CLI-independence explanation, and route to the provider browser flow. Rename `Re-login…` to `Sign in again…` for every account. Add confirmation to `Remove Account…`.

**Step 3: Verify and commit**

Run: `swift test --filter 'OAuthTests|AccountActionsTests'`
Expected: PASS.

Commit: `git add Sources/AIStatusBar/OAuthFlow.swift Sources/AIStatusBar/main.swift Tests/AIStatusBarTests/OAuthTests.swift Tests/AIStatusBarTests/AccountActionsTests.swift && git commit -m "feat: unify account add and recovery"`

### Task 4: Apply the approved menu hierarchy and account-level status language

**Files:**
- Modify: `Sources/AIStatusBar/MenuRows.swift`
- Modify: `Sources/AIStatusBar/main.swift`
- Create: `Tests/AIStatusBarTests/MenuPresentationTests.swift`
- Modify: `Tests/AIStatusBarTests/RowRenderTests.swift`

**Step 1: Write failing presentation tests**

Test the compact 260-point initial width, expansion across AppKit's final menu width, per-chip hover labels, accessible account titles, `Session expired`, `Last data retained`, and the absence of CLI instructions and manual-refresh text from the presentation model.

Run: `swift test --filter 'MenuPresentationTests|RowRenderTests'`
Expected: FAIL because the header and presentation helpers do not exist.

**Step 2: Implement the menu**

Remove the column header and `Updated HH:mm`, keep no `Refresh Now`, narrow the row to its content, add explicit 5-hour/weekly hover help, move settings into a submenu, add `About AI Status Bar`, and render per-account stale/auth language with richer VoiceOver titles.

**Step 3: Verify and commit**

Run: `swift test --filter 'MenuPresentationTests|RowRenderTests'`
Expected: PASS.

Commit: `git add Sources/AIStatusBar/MenuRows.swift Sources/AIStatusBar/main.swift Tests/AIStatusBarTests/MenuPresentationTests.swift Tests/AIStatusBarTests/RowRenderTests.swift && git commit -m "feat: simplify the status bar menu"`

### Task 5: Full verification, documentation, and visual proof

**Files:**
- Modify: `README.md`
- Modify: `PAPERCUTS.md` only if new repository friction occurs in this worktree

**Step 1: Update user documentation**

Document one browser-based add flow, independent CLI sessions, soft migration, Keychain ownership, automatic refresh, and recovery behavior. Remove folder-picker instructions.

**Step 2: Run the full verification suite**

Run: `swift test`
Expected: all tests pass.

Run: `swift build -c release`
Expected: release build succeeds.

Run: `AISTATUSBAR_MOCK=1 swift run AIStatusBar`
Expected: the actual menu matches the approved hierarchy and account states.

**Step 3: Capture visual proof and commit**

Capture the real mock-mode menu to `~/Downloads`, inspect it at original resolution, then commit docs and any final test-safe polish.

Commit: `git add README.md docs/superpowers/specs/2026-08-26-unified-account-ux.md docs/superpowers/plans/2026-08-26-unified-account-ux.md && git commit -m "docs: explain reliable account ownership"`
