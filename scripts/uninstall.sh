#!/usr/bin/env bash
# Removes Cove, its CLI tools and its agent hooks. Your config in ~/.config/cove is kept.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${COVE_BIN_DIR:-$HOME/.local/bin}"

pkill -x Cove 2>/dev/null || true
COVE_BIN_DIR="$BIN_DIR" "$ROOT/scripts/install-hooks.sh" --uninstall
rm -rf "/Applications/Cove.app" "$HOME/Applications/Cove.app" "$HOME/Library/Application Support/Cove/browser-extension"
for tool in cove-notify cove-run cove-claude-hook cove-claude-permission cove-codex-notify; do
  rm -f "$BIN_DIR/$tool"
done
echo "✓ Cove removed (config left in ~/.config/cove)"
