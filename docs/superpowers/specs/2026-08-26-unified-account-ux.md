# Unified Account UX Design

**Date:** 2026-08-26
**Status:** Approved through menu, add-account, and reconnect mockups

## Goal

AI Status Bar should be a small, reliable account monitor. Adding and repairing an account must happen inside the app, without teaching the user about `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, or CLI credential files.

## Product contract

1. The main menu shows compact account rows without a header row. Each usage chip identifies its window on hover.
2. There is one `Add Account…` action. It asks for Claude or Codex, explains that browser sign-in opens next, and states that CLI accounts are not changed.
3. Both providers use browser OAuth. New sessions are stored by AI Status Bar in macOS Keychain and refreshed by AI Status Bar.
4. Existing CLI-backed accounts remain readable. `Sign in again…` converts the selected row to app-owned credentials while preserving its UUID, name, order, and retained usage data.
5. Authentication failure stays visible as `Session expired`, retains the last good values, and exposes `Sign in again…`. A network failure is shown as offline and does not imply that login is broken.

## Main menu

- Keep the native `NSMenu`, equalizer status icon, compact account rows, threshold colors, and account detail submenus.
- Keep the menu no wider than its account content; use a 260-point custom row that expands across AppKit's final menu width instead of the previous fixed 400-point row.
- Match account submenu chevrons to the native Settings chevron in weight, contrast, and right alignment.
- Do not add a column header. The left chip is the 5-hour window and the right chip is the weekly window; native hover help names each one explicitly.
- Remove the global `Updated HH:mm` row. Freshness belongs to an account and appears only when that account is stale.
- Do not add `Refresh Now`. The app already polls in the background and immediately when the menu opens.
- Replace the three provider/source-specific add actions with one `Add Account…`.
- Move `Launch at Login`, `Usage Alerts`, and `Check for Updates…` into `Settings`.
- Keep `About AI Status Bar` and `Quit AI Status Bar` as top-level actions.

## Account submenu

- Show identity, provider, and plan first.
- For healthy accounts, keep the detailed 5-hour and weekly reset rows.
- For expired authentication, show `Session expired` and `Last data retained` before the action.
- Every account kind has `Sign in again…`; legacy accounts use it as the soft migration path.
- Rename stays available. `Remove Account…` requires confirmation and deletes only the app's own Keychain item.

## Credential ownership

### New Claude account

Use the existing Claude PKCE browser flow. Persist access token, refresh token, and expiry in the `AIStatusBar` Keychain service.

### New Codex account

Use Codex's browser PKCE flow with a loopback callback. Persist access token, refresh token, ID token when returned, and expiry in the same app-owned Keychain service. Proactively refresh before expiry and persist every rotated token.

### Legacy accounts

`claudeMain` and `codex` continue to read existing CLI credentials so the upgrade is nondestructive. AI Status Bar must not refresh or write those credentials. On reconnect, the selected account changes to `claudeOAuth` or `codexOAuth`; its legacy source path is cleared, and builtin rediscovery is dismissed for that provider when applicable.

## Accessibility and error language

- VoiceOver titles include account identity, provider, 5-hour value, weekly value, and stale/expired state.
- User-facing recovery text says what to do in the app: `Sign in again…`, never `run codex login`, `open Claude Code`, or `re-login CLI profile`.
- OAuth errors name the provider and give a retry action; tokens and raw responses are never displayed or logged.

## Non-goals

- Do not modify Claude Code or Codex CLI login state.
- Do not import, copy, or rewrite CLI refresh tokens during migration.
- Do not remove legacy account discovery in this release.
- Do not add manual refresh, account-folder pickers, or background daemons.
