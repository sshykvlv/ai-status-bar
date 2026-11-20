# AI Status Bar

A menu bar app that shows how much usage you have left on multiple Claude accounts, Codex, and Grok, at a glance.

![AI Status Bar menu](docs/screenshot.png)

## Install

```
brew install --cask sshykvlv/tap/ai-status-bar
```

Or download `AIStatusBar.zip` from [Releases](https://github.com/sshykvlv/ai-status-bar/releases) and unzip it to `/Applications`.

The in-app updater verifies each download in an isolated staging directory, then reveals a signed, versioned `.app` in Downloads. It never replaces an existing download or the running application automatically.

## Usage

Your existing Claude Code, Codex, and Grok CLI accounts are detected automatically so an upgrade does not lose any rows.

On first launch macOS will ask to allow access to the "Claude Code-credentials" Keychain item — that's the app reading your existing Claude Code login (read-only, see Privacy below) to show its usage. Click **Always Allow** and you're set.

Use **Add Account…**, choose Claude or Codex, and finish sign-in in your browser. AI Status Bar stores that session separately in macOS Keychain, refreshes it automatically, and never changes which account Claude Code or Codex CLI uses.

If an older Claude or Codex CLI-backed row expires, open its submenu and choose **Sign in again…**. The row keeps its name and position, then becomes app-owned so it no longer depends on a CLI folder or login.

Grok is detected from your Grok CLI login and shows the percentage used from its weekly pool plus the reset time. Free accounts do not report a pool percentage, so they honestly show `—`; if the token expires, run `grok` in Terminal to refresh it.

The icon is a mini equalizer: one continuous bar per account. Its height shows the exact percentage used; its color shifts gradually from green through yellow and orange to red as usage rises. Exact percentages remain in the tooltip.

If a provider omits a usage window or its percentage, the app shows no data (`—`) instead of inventing `0%`. Codex windows are matched by their reported duration when available, with the legacy primary/secondary ordering retained as a fallback.

Open an account submenu to see reset times, forecasts, connection status, and when the displayed data was last updated. VoiceOver announces the same window values, status, and freshness from the compact account row.

Each chip is labelled with its window — `5H · 42%`, `7D · 87%`. At 70% and above it turns into a soft orange plate, at 90% into a red one; text on both stays readable in light and dark mode.

### Mac stats

When agents make the Mac crawl, the **Mac** block under the accounts tells you why without asking them:

- **Mac** shows two chips, `CPU 54%` and `RAM 18/24 GB`. Only the one that is in trouble lights up: CPU turns orange at 70% and red at 90%, RAM follows macOS memory pressure. Its submenu has memory, swap and CPU, plus **Open Activity Monitor**.
- The three rows below are the biggest consumers. Agent sessions absorb their helpers (`Claude Code ×6 — 6.4 GB` includes every MCP server and `node` they started); apps absorb their helper processes. When CPU is the bottleneck, the rows rank by CPU instead.
- Each row's submenu has **Quit** and **Force Quit**. Agent sessions and every force quit ask first.
- **Leftovers** are agent helpers whose session already exited (parent gone, its process group dead, a `node`/`python`/`uv`/MCP tool). They are listed by script name — some may be servers you detached on purpose, so nothing is killed until you click.
- Swap has no "clear" button: macOS drains it on its own once memory frees up.

Turn the block off in **Settings → Show Mac Stats**. Design and rules: [`docs/superpowers/specs/2026-11-16-mac-stats-design.md`](docs/superpowers/specs/2026-11-16-mac-stats-design.md).

## Privacy

All requests go directly from your Mac to Anthropic, OpenAI, and xAI. No servers, no telemetry. New OAuth sessions live only in your macOS Keychain. Existing Claude Code and Codex credentials are read locally as a compatibility layer; AI Status Bar never writes or refreshes them. Grok credentials are read from `~/.grok/auth.json` (or `$GROK_HOME/auth.json`) read-only and are never written or refreshed. Mac stats are read from the local kernel; process names and command lines never leave your Mac, and only processes you own can be quit.

## Credits

Thanks to [steipete/CodexBar](https://github.com/steipete/CodexBar) (MIT) whose docs documented the usage endpoints this app relies on.

## License

MIT — see [LICENSE](LICENSE).
