#!/bin/bash
# Signs Developer ID + notarizes + staples + packages a zip for release.
# Requires: a "Developer ID Application" certificate in your keychain, and a
# notarytool keychain profile. One-time setup:
#   xcrun notarytool store-credentials aistatusbar-notary \
#       --apple-id YOU@APPLEID --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
#
# Usage: ./release.sh [version] [profile]
#   version  optional — if given, bumps CFBundleShortVersionString in Info.plist
#            before building (e.g. ./release.sh 0.2.0)
#   profile  optional — notarytool keychain profile name (default: aistatusbar-notary)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
PROFILE="${2:-aistatusbar-notary}"
APP="AIStatusBar.app"
OUT="$HOME/Downloads/AIStatusBar.zip"

# 0) optional version bump (skip if already set — PlistBuddy reformats the
# whole plist even on a no-op Set, dirtying the tree for nothing)
if [ -n "$VERSION" ]; then
    CURRENT="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)"
    if [ "$CURRENT" != "$VERSION" ]; then
        echo "🔖 Bumping CFBundleShortVersionString $CURRENT → $VERSION"
        /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
        echo "⚠️  Info.plist changed — commit it with the release."
    fi
fi

# 0.5) tests — NOT `swift test` (hangs on a Keychain dialog); xctest directly
echo "🧪 Running tests…"
swift build --build-tests
# Путь к бандлу — через --show-bin-path, а не хардкодом: Swift 6.4 сменил
# раскладку на .build/out/Products/Debug/<Target>Tests.xctest, и старый путь
# молча ронял релиз (set -e + pipefail, без сообщения).
TEST_BUNDLE="$(find "$(swift build --show-bin-path)" -maxdepth 1 -name '*.xctest' | head -1)"
if [ -z "$TEST_BUNDLE" ]; then
    echo "❌ Test bundle not found under $(swift build --show-bin-path) — aborting release." >&2
    exit 1
fi
TEST_OUT="$(xcrun xctest "$TEST_BUNDLE" 2>&1 | grep -E 'Executed [0-9]+ tests, with' | tail -1 || true)"
echo "   $TEST_OUT"
case "$TEST_OUT" in
    # Matched without the "with" prefix — a real run always has 2 skipped tests
    # (owner-only Keychain/render checks gated by env vars), so "with 0 failures"
    # never matches; "0 failures (0 unexpected)" is stable whether or not tests skip.
    *"0 failures (0 unexpected)"*) ;;
    *) echo "❌ Tests failed — aborting release." >&2; exit 1 ;;
esac

# 1) fresh build
./build.sh

# 2) find Developer ID Application identity
IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(Developer ID Application[^"]*)".*/\1/')"
if [ -z "${IDENTITY:-}" ]; then
    echo "❌ No 'Developer ID Application' certificate in keychain." >&2
    echo "   Create one: Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application" >&2
    exit 1
fi
echo "🔏 Signing as: $IDENTITY"

# 3) sign with hardened runtime + timestamp (required for notarization)
codesign --force --options runtime --timestamp \
    --sign "$IDENTITY" "build/$APP"
codesign --verify --strict --verbose=2 "build/$APP"

# 4) notarize (zip → submit → wait)
ZIP_TMP="$(mktemp -d)/AIStatusBar.zip"
ditto -c -k --keepParent "build/$APP" "$ZIP_TMP"
echo "📤 Submitting for notarization (profile: $PROFILE)…"
xcrun notarytool submit "$ZIP_TMP" --keychain-profile "$PROFILE" --wait

# 5) staple — so it opens offline without an Apple check
xcrun stapler staple "build/$APP"

# 6) gate — what Gatekeeper will see on another Mac; a fail here means the
# artifact is broken for users even if notarization "succeeded"
echo "🔎 Gatekeeper check:"
if ! spctl -a -vvv "build/$APP"; then
    echo "❌ Gatekeeper rejected the app — do NOT ship this artifact." >&2
    exit 1
fi

# 7) final zip for distribution
rm -f "$OUT"
ditto -c -k --keepParent "build/$APP" "$OUT"
# checksums alongside the release (integrity verification + cask sha256)
( cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")" > SHA256SUMS )
echo "✅ Done: $OUT (+ SHA256SUMS) — ready to attach to the GitHub release."
