# Papercuts

## 2026-07-18 16:39 — Sonnet 5
Owner reported another macOS keychain prompt from AI Status Bar, hours after this morning's fix (re-signing ~/Applications/AIStatusBar.app with the Developer ID cert). Root cause: `build.sh` (local dev/test build) still ad-hoc signed (`codesign --sign -`), so every local rebuild got a fresh, hash-pinned code identity that invalidates prior Keychain "Always Allow" grants — separate from the release path in `release.sh`, which already used the Developer ID cert. Fixed `build.sh` to sign with the same Developer ID Application cert (hardened runtime, falls back to ad-hoc if no cert present, e.g. CI). Verified: rebuilt binary's CDHash now matches the installed release build exactly, confirming a stable, reproducible identity across rebuilds.

## 2026-07-21 09:20 — Sonnet 5
`log` (the `/usr/bin/log` CLI, used to inspect unified system logs — securityd/coreauthd Keychain events, this app's own OSLog output) is shadowed by a zsh builtin in this shell: bare `log show ...` fails with `(eval):log:1: too many arguments` instead of running the real binary. Every `log show` call earlier in this session had its stderr redirected to `/dev/null`, so the shadowing failure was silent and looked identical to "no matching log entries" — led to a wrong "zero evidence" conclusion that had to be walked back once caught. Fix: always invoke `/usr/bin/log` explicitly (or `command log`) in this environment, never bare `log`.

## 2026-09-27 14:17 — GPT-5.6 Sol
Building the segmented-icon contact sheet with ImageMagick `montage -label` → the default font resolved to an empty name, emitted `unable to read font`, and silently omitted labels. Pass an explicit installed font before the input images, or compose the labels separately.

## 2026-09-27 14:19 — GPT-5.6 Sol
Packaging a verified local app with `build.sh` after Swift 6.4 compiled successfully → the script copied from the old hardcoded `.build/apple/Products/Release` layout, while Swift now emitted `.build/out/Products/Release`. Resolve the product directory through `swift build --show-bin-path` instead of depending on toolchain internals.

## 2026-09-27 15:26 — GPT-5.6 Sol
Looking for an optional pull-request template with `rg --files .github` → the repository has no `.github` directory, so ripgrep returned a noisy IO error during an otherwise clean pre-PR check. Guard optional directories with `[ -d .github ]` before scanning them.

## 2026-09-27 16:48 — GPT-5.6 Sol
Loading the TDD skill's `writing-good-tests.md` reference from the shared skill root → that path does not exist because the reference lives inside `test-driven-development/`. Resolve relative references from the directory containing the selected `SKILL.md`.

## 2026-09-27 17:18 — GPT-5.6 Sol
Running release verification while the read-only reviewer also invoked SwiftPM in the shared worktree → `build.sh` waited on the shared `.build` lock. Review packets should ask reviewers to inspect existing test evidence without starting SwiftPM while root verification is active.
