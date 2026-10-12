#!/usr/bin/env bash
# Builds build/Cove.app from the Swift package.
#
# Signing: by default the app is ad-hoc signed, which means macOS forgets its permissions
# (Full Disk Access, Automation) every time you rebuild. To keep them, create a self-signed
# "Code Signing" certificate in Keychain Access once (e.g. named "Cove Dev") and run:
#   COVE_SIGN_IDENTITY="Cove Dev" ./scripts/build-app.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "→ Building Cove (release)…"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/Cove"

APP="$ROOT/build/Cove.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cove"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -d "$ROOT/Resources/AppIcon.iconset" ]; then
  iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

IDENTITY="${COVE_SIGN_IDENTITY:--}"
echo "→ Signing with identity: $IDENTITY"
codesign --force --sign "$IDENTITY" "$APP"

echo "✓ Built $APP"
