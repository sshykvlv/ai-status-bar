# AI Status Bar

A menu bar app that shows how much usage you have left on multiple Claude accounts and Codex, at a glance.

![AI Status Bar menu](docs/screenshot.png)

## Install

```
brew install --cask sshykvlv/tap/ai-status-bar
```

Or download `AIStatusBar.zip` from [Releases](https://github.com/sshykvlv/ai-status-bar/releases) and unzip it to `/Applications`.

The in-app updater verifies each download in an isolated staging directory, then reveals a signed, versioned `.app` in Downloads. It never replaces an existing download or the running application automatically.

## Usage

Your existing Claude Code and Codex accounts are detected automatically so an upgrade does not lose any rows.

On first launch macOS will ask to allow access to the "Claude Code-credentials" Keychain item — that's the app reading your existing Claude Code login (read-only, see Privacy below) to show its usage. Click **Always Allow** and you're set.

Use **Add Account…**, choose Claude or Codex, and finish sign-in in your browser. AI Status Bar stores that session separately in macOS Keychain, refreshes it automatically, and never changes which account Claude Code or Codex CLI uses.

If an older CLI-backed row expires, open its submenu and choose **Sign in again…**. The row keeps its name and position, then becomes app-owned so it no longer depends on a CLI folder or login.

The icon is a mini equalizer: one continuous bar per account. Its height shows the exact percentage used; its color shifts gradually from green through yellow and orange to red as usage rises. Exact percentages remain in the tooltip.

If a provider omits a usage window or its percentage, the app shows no data (`—`) instead of inventing `0%`. Codex windows are matched by their reported duration when available, with the legacy primary/secondary ordering retained as a fallback.

Open an account submenu to see reset times, forecasts, connection status, and when the displayed data was last updated. VoiceOver announces the same window values, status, and freshness from the compact account row.

## Privacy

All requests go directly from your Mac to Anthropic and OpenAI. No servers, no telemetry. New OAuth sessions live only in your macOS Keychain. Existing Claude Code and Codex credentials are read locally as a compatibility layer; AI Status Bar never writes or refreshes them.

## Credits

Thanks to [steipete/CodexBar](https://github.com/steipete/CodexBar) (MIT) whose docs documented the usage endpoints this app relies on.

## License

MIT — see [LICENSE](LICENSE).
