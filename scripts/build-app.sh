#!/usr/bin/env bash
# Builds build/Cove.app from the Swift package.
#
# Signing: uses a local "Cove Local Signing" certificate (created once by
# scripts/make-signing-identity.sh) so macOS keeps permissions across rebuilds.
# Override with COVE_SIGN_IDENTITY="Your Identity" or COVE_SIGN_IDENTITY="-" for ad-hoc.
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
# Bundle the CLI tools and browser extension so Settings can install them without this repo.
mkdir -p "$APP/Contents/Resources/bin"
cp "$ROOT"/bin/* "$APP/Contents/Resources/bin/"
chmod 755 "$APP/Contents/Resources/bin/"*
cp -R "$ROOT/extension" "$APP/Contents/Resources/extension"

if [ -d "$ROOT/Resources/AppIcon.iconset" ]; then
  iconutil -c icns "$ROOT/Resources/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Sign with a stable local certificate so macOS keeps Cove's permissions across rebuilds.
# (CI builds stay ad-hoc.) Falls back to ad-hoc if the certificate can't be made or used.
IDENTITY="${COVE_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && [ -z "${CI:-}" ]; then
  IDENTITY="$("$ROOT/scripts/make-signing-identity.sh" 2>/dev/null || true)"
fi
[ -z "$IDENTITY" ] && IDENTITY="-"
echo "→ Signing with: $([ "$IDENTITY" = "-" ] && echo "ad-hoc signature" || echo "$IDENTITY")"
if ! codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "  (couldn't use \"$IDENTITY\"; falling back to an ad-hoc signature)"
  codesign --force --sign - "$APP"
fi

echo "✓ Built $APP"
