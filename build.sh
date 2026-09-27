#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
APP=build/AIStatusBar.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/AIStatusBar" "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources"
cp icon/AppIcon.icns "$APP/Contents/Resources/"
# Sign with the Developer ID cert when available so local rebuilds keep a
# stable code identity — an ad-hoc signature changes every build, which
# invalidates Keychain "Always Allow" grants and re-prompts on every launch.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(Developer ID Application[^"]*)".*/\1/')"
if [ -n "${IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP"
