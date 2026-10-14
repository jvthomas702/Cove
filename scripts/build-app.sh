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
BUILD_PATH="${COVE_BUILD_PATH:-$ROOT/.build}"
if [ "${COVE_UNIVERSAL:-0}" = "1" ]; then
  BINS=()
  for ARCH in arm64 x86_64; do
    swift build -c release --arch "$ARCH" --scratch-path "$BUILD_PATH/$ARCH"
    BINS+=("$(swift build -c release --arch "$ARCH" --scratch-path "$BUILD_PATH/$ARCH" --show-bin-path)/Cove")
  done
  BIN="$BUILD_PATH/Cove-universal"
  lipo -create "${BINS[@]}" -output "$BIN"
  SPARKLE="$(python3 scripts/sparkle-path.py "$BUILD_PATH/arm64")"
else
  swift build -c release --scratch-path "$BUILD_PATH"
  BIN="$(swift build -c release --scratch-path "$BUILD_PATH" --show-bin-path)/Cove"
  SPARKLE="$(python3 scripts/sparkle-path.py "$BUILD_PATH")"
fi

APP="$ROOT/build/Cove.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cove"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/Resources/Sparkle-LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE"
cp -R "$ROOT/Resources/TeamLogos" "$APP/Contents/Resources/TeamLogos"
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
python3 scripts/sign-sparkle.py "$APP/Contents/Frameworks/Sparkle.framework" "$IDENTITY"
echo "→ Signing with: $([ "$IDENTITY" = "-" ] && echo "ad-hoc signature" || echo "$IDENTITY")"
if ! codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
  echo "  (couldn't use \"$IDENTITY\"; falling back to an ad-hoc signature)"
  codesign --force --sign - "$APP"
fi

echo "✓ Built $APP"
