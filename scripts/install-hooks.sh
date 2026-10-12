#!/usr/bin/env bash
# Wires Claude Code and Codex up to Cove.
#
#   ./scripts/install-hooks.sh              add hooks
#   ./scripts/install-hooks.sh --uninstall  remove them
#
# Claude Code: merges hook entries into ~/.claude/settings.json (a backup is written first).
# Codex:       adds `notify = [...]` to the top of ~/.codex/config.toml.
set -euo pipefail

MODE="install"
[ "${1:-}" = "--uninstall" ] && MODE="uninstall"

BIN_DIR="${COVE_BIN_DIR:-$HOME/.local/bin}"
CLAUDE_HOOK="$BIN_DIR/cove-claude-hook"
CLAUDE_PERMISSION="$BIN_DIR/cove-claude-permission"
CODEX_NOTIFY="$BIN_DIR/cove-codex-notify"

# ---------- Claude Code ----------
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$CLAUDE_SETTINGS" ] && cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.cove-backup"

# JavaScript for Automation ships with macOS, so no jq/python dependency.
/usr/bin/osascript -l JavaScript - "$CLAUDE_SETTINGS" "$CLAUDE_HOOK" "$CLAUDE_PERMISSION" "$MODE" <<'JXA'
ObjC.import('Foundation');
function run(argv) {
  const [path, cmd, permissionCmd, mode] = argv;
  const ours = [cmd, permissionCmd];
  const raw = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, null));
  let settings = {};
  if (raw && raw.trim().length) settings = JSON.parse(raw);
  settings.hooks = settings.hooks || {};
  // Event → [command, timeout seconds, matcher]
  const wanted = {
    UserPromptSubmit: [cmd, 5],
    PreToolUse: [cmd, 5, '*'],
    Notification: [cmd, 5],
    Stop: [cmd, 5],
    SessionEnd: [cmd, 5],
    // Waits for your click in the notch; Cove gives up well before this timeout.
    PermissionRequest: [permissionCmd, 120, '*'],
  };
  for (const ev of Object.keys(wanted)) {
    let groups = settings.hooks[ev] || [];
    // Always drop our old entries first, so re-running never duplicates them.
    groups = groups
      .map(g => Object.assign({}, g, { hooks: (g.hooks || []).filter(h => !ours.includes(h.command)) }))
      .filter(g => g.hooks.length > 0);
    if (mode === 'install') {
      const [command, timeout, matcher] = wanted[ev];
      const group = { hooks: [{ type: 'command', command: command, timeout: timeout }] };
      if (matcher) group.matcher = matcher;
      groups.push(group);
    }
    if (groups.length) settings.hooks[ev] = groups; else delete settings.hooks[ev];
  }
  if (Object.keys(settings.hooks).length === 0) delete settings.hooks;
  $(JSON.stringify(settings, null, 2) + '\n').writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, null);
  return mode === 'install' ? 'Claude Code hooks installed' : 'Claude Code hooks removed';
}
JXA

# ---------- Codex ----------
CODEX_CFG="$HOME/.codex/config.toml"
if [ "$MODE" = "install" ]; then
  if [ -d "$HOME/.codex" ] || command -v codex >/dev/null 2>&1; then
    mkdir -p "$HOME/.codex"
    touch "$CODEX_CFG"
    if grep -q 'cove-codex-notify' "$CODEX_CFG"; then
      echo "Codex notify already points at Cove"
    elif grep -qE '^[[:space:]]*notify[[:space:]]*=' "$CODEX_CFG"; then
      echo "⚠ Codex already has a notify program. To add Cove, edit $CODEX_CFG and set:"
      echo "    notify = [\"$CODEX_NOTIFY\"]"
    else
      cp "$CODEX_CFG" "$CODEX_CFG.cove-backup"
      # notify must be a top-level key, so it goes before any [table].
      { printf 'notify = ["%s"]\n' "$CODEX_NOTIFY"; cat "$CODEX_CFG.cove-backup"; } > "$CODEX_CFG"
      echo "Codex notify installed"
    fi
  fi
else
  if [ -f "$CODEX_CFG" ] && grep -q 'cove-codex-notify' "$CODEX_CFG"; then
    grep -v 'cove-codex-notify' "$CODEX_CFG" > "$CODEX_CFG.tmp" && mv "$CODEX_CFG.tmp" "$CODEX_CFG"
    echo "Codex notify removed"
  fi
fi
