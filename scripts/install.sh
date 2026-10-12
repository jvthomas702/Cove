#!/usr/bin/env bash
# One-shot install: build the app, put it in Applications, install the CLI tools,
# hook up Claude Code + Codex, and launch Cove.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/build-app.sh"

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
for tool in cove-notify cove-run cove-claude-hook cove-codex-notify; do
  install -m 755 "$ROOT/bin/$tool" "$BIN_DIR/$tool"
done

echo "→ Connecting agents"
COVE_BIN_DIR="$BIN_DIR" "$ROOT/scripts/install-hooks.sh"

open "$DEST/Cove.app"

echo
echo "✓ Cove is running — hover the notch."
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) echo "  Add the CLI tools to your PATH:  echo 'export PATH=\"$BIN_DIR:\$PATH\"' >> ~/.zshrc" ;;
esac
echo "  Mirror notifications: System Settings → Privacy & Security → Full Disk Access → add Cove, then relaunch it."
echo "  Try it: menu bar capsule icon → Run demo"
