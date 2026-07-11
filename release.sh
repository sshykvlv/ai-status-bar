#!/bin/bash
# Signs Developer ID + notarizes + staples + packages a zip for release.
# Requires: a "Developer ID Application" certificate in your keychain, and a
# notarytool keychain profile. One-time setup:
#   xcrun notarytool store-credentials limitbar-notary \
#       --apple-id YOU@APPLEID --team-id TEAMID --password xxxx-xxxx-xxxx-xxxx
#
# Usage: ./release.sh [version] [profile]
#   version  optional — if given, bumps CFBundleShortVersionString in Info.plist
#            before building (e.g. ./release.sh 0.2.0)
#   profile  optional — notarytool keychain profile name (default: limitbar-notary)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
PROFILE="${2:-limitbar-notary}"
APP="LimitBar.app"
OUT="$HOME/Downloads/LimitBar.zip"

# 0) optional version bump
if [ -n "$VERSION" ]; then
    echo "🔖 Bumping CFBundleShortVersionString to $VERSION"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
fi

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
ZIP_TMP="$(mktemp -d)/LimitBar.zip"
ditto -c -k --keepParent "build/$APP" "$ZIP_TMP"
echo "📤 Submitting for notarization (profile: $PROFILE)…"
xcrun notarytool submit "$ZIP_TMP" --keychain-profile "$PROFILE" --wait

# 5) staple — so it opens offline without an Apple check
xcrun stapler staple "build/$APP"

# 6) sanity check — what Gatekeeper will see on another Mac
echo "🔎 Gatekeeper check:"
spctl -a -vvv "build/$APP" 2>&1 || true

# 7) final zip for distribution
rm -f "$OUT"
ditto -c -k --keepParent "build/$APP" "$OUT"
# checksums alongside the release (integrity verification + cask sha256)
( cd "$(dirname "$OUT")" && shasum -a 256 "$(basename "$OUT")" > SHA256SUMS )
echo "✅ Done: $OUT (+ SHA256SUMS) — ready to attach to the GitHub release."
