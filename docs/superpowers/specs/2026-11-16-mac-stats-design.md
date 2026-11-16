# Mac stats block — design

Status: approved by owner 16.11.2026 («го» after the live-menu spike and the Fable minimal pass).

## Intent

While several coding agents run, the Mac slows down. The owner wants to see in one second
*what* is eating the machine — without asking the agents — and to close it right from the
menu. AI Status Bar already lives in the menu bar, so the block goes there.

## Goals

- One summary row «Mac» with a single verdict chip naming the bottleneck.
- Top 3 consumers by memory (by CPU when CPU is the bottleneck), grouped so that an agent
  session absorbs its helpers: «Claude Code ×11 — 7.4 GB», not «node ×104».
- Close a consumer from its submenu: Quit / Force Quit.
- Find agent leftovers (helpers whose session died) and offer to quit them — each one
  listed by a readable name, never killed silently.

## Non-goals / anti-goals

- No automatic killing, no thresholds that act on their own.
- No "clear swap" button: swap drains by itself once memory frees; `purge` needs admin.
- No new menu-bar icon indicator (minimalism; the menu is the diagnosis surface).
- No dependency on the owner's local scripts (`mac-tuneup.sh`): the app is public (brew cask).
- No network, no telemetry — everything is read from the local kernel.

## Look (approved)

```
Mac                        [Swap 16 GB] ›   ← one chip; colour only when alarming
Claude Code ×11                 7.4 GB  ›   ← plain text, rank = order
Google Chrome                   4.8 GB  ›
Codex ×3                        2.1 GB  ›
```

- Chip colours: `asbWarnFill` #B85A00 / `asbDangerFill` #D92D20 with white text
  (4.7:1 / 4.8:1, WCAG AA). The same filled chips now mark ≥70 % / ≥90 % usage windows.
- Calm state: grey chip «RAM 18/24 GB».
- Consumers: regular weight, memory in `labelColor`, no chip, no colour.
- «Mac» submenu: pressure line (only when not normal), Memory / Swap / CPU lines,
  «Leftovers ×N ›» (when not already in the top 3), «Open Activity Monitor».
- Consumer submenu: «N processes · M helpers», separator, «Quit All N» / «Force Quit All N».
- Leftovers submenu: one line per leftover («relay.py — uv · 2 h · 9 MB», click = quit),
  «Quit All Leftovers».
- Settings gets a «Show Mac Stats» toggle (default on).

## Verdict rule

- Memory alarm comes from `kern.memorystatus_vm_pressure_level` (1 normal, 2 warn,
  4 critical), not from «% RAM used» — macOS keeps RAM full on purpose, and swap used is
  history (observed 16.11: 9 GB swap with pressure normal).
- CPU alarm: total CPU ≥70 % warn, ≥90 % critical (same thresholds as usage windows).
- Text: memory alarm → «Swap N GB» if swap ≥1 GB else «RAM u/t GB»; CPU alarm → «CPU N%».
  Ties go to memory; CPU wins only when strictly worse. Calm → «RAM u/t GB», grey.

## Approaches considered

1. **Group by process name** (Activity Monitor style) — rejected: «node ×104» does not say
   whose node it is.
2. **Group by ownership tree** — chosen. Each process is attributed to, in order:
   the outermost known agent CLI among itself and its ancestors (`claude`, `codex`,
   `gemini`, `opencode`, `aider`, `cursor-agent`, `amp`) → «Claude Code», «Codex», …;
   else its own `.app` bundle (outermost, so Chrome helpers → «Google Chrome»);
   else its executable name. Count = number of group roots (processes whose parent is
   outside the group); helpers = the rest.
3. **Shell out to `ps`/`top`** — rejected: slower, locale-fragile; the kernel APIs
   (`proc_listallpids`, `proc_pidinfo`, `proc_pid_rusage`, `host_statistics64`, `sysctl`)
   give the same data in-process.

Memory per process = `ri_phys_footprint` (what Activity Monitor shows), not RSS.

## Leftover rule

A process is a leftover when all hold: owned by the current user; `ppid == 1`;
`pgid != pid` and no live process has `pid == pgid` (its session leader died — launchd
jobs are their own group leaders, so they never match); executable not inside a `.app`
bundle and not under `/System` or `/usr/libexec`; name is agent tooling (`node`, `bun`,
`deno`, `python*`, `uv`, `uvx`, `npx`, `npm`, `pnpm`, `tsx`) or contains `mcp`; alive
≥60 s. Checked on the owner's Mac 16.11: 586 user processes with ppid 1 → exactly 1 match
(`uv run … relay.py serve`), which may be a deliberately detached server — hence the
listing with names and explicit clicks.

## Actions and safety

- Only processes owned by the current user; never pid 0/1, this app, or its ancestors.
- `.app` groups: `NSRunningApplication.terminate()` / `forceTerminate()` (the app gets to
  save state).
- Agent and CLI groups: Quit = SIGTERM to the roots (they shut their helpers);
  Force Quit = SIGKILL descendants first, then roots (so nothing becomes a new leftover).
- Agent groups and every Force Quit ask for confirmation (an agent session's work stops).
- A leftover's Quit = SIGTERM to it and its descendants.

## Sampling

Background sample every 10 s on a utility queue (≈ a few ms for ~800 processes); an
immediate sample when the menu opens; every 2 s while it is open, rows updated in place
(the menu must not be rebuilt while open — see the «gap under Quit» note in `main.swift`).
CPU % = delta of CPU time between samples / wall time / cores. The block keeps a fixed
row count (summary + 3) so in-place updates never change menu height.

## Left to the builder

Exact file split, the mach timebase conversion for `ri_user_time`, the script-name
heuristic for leftover labels, test fixtures.
