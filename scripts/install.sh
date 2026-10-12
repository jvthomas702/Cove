#!/usr/bin/env bash
# One-shot install: build the app, put it in Applications, install the CLI tools,
# hook up Claude Code + Codex, and launch Cove.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
echo "→ Installing Cove $VERSION"

if ! "$ROOT/scripts/build-app.sh"; then
  echo
  echo "✗ The build failed, so your old Cove is still installed."
  echo "  Copy the lines containing 'error:' above and send them over."
  exit 1
fi

DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

echo "→ Installing Cove.app to $DEST"
pkill -x Cove 2>/dev/null || true
sleep 0.5
rm -rf "$DEST/Cove.app"
cp -R "$ROOT/build/Cove.app" "$DEST/"

BIN_DIR="${COVE_BIN_DIR:-$HOME/.local/bin}"
echo "→ Installing CLI tools to $BIN_DIR"
mkdir -p "$BIN_DIR"
for tool in cove-notify cove-run cove-claude-hook cove-claude-permission cove-codex-notify; do
  install -m 755 "$ROOT/bin/$tool" "$BIN_DIR/$tool"
done

echo "→ Connecting agents"
COVE_BIN_DIR="$BIN_DIR" "$ROOT/scripts/install-hooks.sh"

EXT_DIR="$HOME/Library/Application Support/Cove/browser-extension"
echo "→ Copying the browser extension to $EXT_DIR"
mkdir -p "$EXT_DIR"
rm -rf "$EXT_DIR"/*
cp -R "$ROOT/extension/." "$EXT_DIR/"

open "$DEST/Cove.app"

echo
echo "✓ Cove $VERSION is running — Pip should be napping beside the notch."
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "  Add the CLI tools to your PATH:  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc" ;;
esac
echo "  macOS will ask for Calendars, Reminders and Accessibility (for the volume/brightness HUD) — allow them."
echo "  Mirror notifications: System Settings → Privacy & Security → Full Disk Access → add Cove, then relaunch it."
echo "  Try it: menu bar icon → Run demo"
echo "  Chat tabs: chrome://extensions → Developer mode → Load unpacked → choose"
echo "             $EXT_DIR"
