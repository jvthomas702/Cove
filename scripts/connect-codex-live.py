#!/usr/bin/env python3
"""Preview by default. --install adds status-only hooks; Codex still requires user trust."""
import argparse
import datetime
import json
from pathlib import Path
import re
import shlex
import shutil
import sys
import tomllib

EVENTS = ("UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SessionEnd")
ROOT = Path(__file__).resolve().parents[1]

def enable_hooks(text):
    data = tomllib.loads(text)
    if data.get("features", {}).get("hooks") is True:
        return text
    if re.search(r"(?m)^features\.hooks\s*=", text):
        result = re.sub(r"(?m)^(features\.hooks\s*=)[^\n]*", r"\1 true", text)
    elif re.search(r"(?m)^\[features\]\s*(?:#.*)?$", text):
        match = re.search(r"(?m)^\[features\]\s*(?:#.*)?$", text)
        start = match.end()
        next_table = re.search(r"(?m)^\[", text[start:])
        end = start + next_table.start() if next_table else len(text)
        section = text[start:end]
        if re.search(r"(?m)^hooks\s*=", section):
            section = re.sub(r"(?m)^(hooks\s*=)[^\n]*", r"\1 true", section)
        else:
            section = "\nhooks = true\n" + section
        result = text[:start] + section + text[end:]
    else:
        if "features" in data:
            raise ValueError("Use a [features] table before enabling live hooks; inline features are preserved.")
        result = text.rstrip() + "\n\n[features]\nhooks = true\n"
    assert tomllib.loads(result)["features"]["hooks"] is True
    return result

def merge_hooks(existing, command):
    output = json.loads(json.dumps(existing))
    hooks = output.setdefault("hooks", {})
    if not isinstance(hooks, dict):
        raise ValueError("hooks must be an object")
    for event in EVENTS:
        groups = hooks.setdefault(event, [])
        if not isinstance(groups, list):
            raise ValueError("hook event must be a list")
        already = any(h.get("command") == command for g in groups for h in g.get("hooks", []))
        if not already:
            group = {"hooks": [{"type": "command", "command": command, "timeout": 1}]}
            if event in ("PreToolUse", "PostToolUse", "PermissionRequest"):
                group["matcher"] = ".*"
            groups.append(group)
    return output

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--install", action="store_true")
    parser.add_argument("--config-dir", type=Path, default=Path.home() / ".codex")
    parser.add_argument("--bin-dir", type=Path, default=Path.home() / ".local/bin")
    args = parser.parse_args()
    target = args.bin_dir / "cove-codex-live.py"
    command = shlex.quote(sys.executable) + " " + shlex.quote(str(target))
    hooks_file = args.config_dir / "hooks.json"
    config_file = args.config_dir / "config.toml"
    existing = json.loads(hooks_file.read_text()) if hooks_file.exists() else {}
    config = config_file.read_text() if config_file.exists() else ""
    updated_config = enable_hooks(config)
    updated_hooks = merge_hooks(existing, command)
    if not args.install:
        print(json.dumps({"command": command, "events": list(EVENTS), "destination": "127.0.0.1 Cove only",
                          "config": str(config_file), "hooks": updated_hooks, "trust": "Review and trust using Codex /hooks"}, indent=2))
        return
    args.config_dir.mkdir(parents=True, exist_ok=True)
    args.bin_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    for path in (config_file, hooks_file, target):
        if path.exists():
            backup = path.with_name(path.name + ".cove-live-backup-" + stamp)
            shutil.copy2(path, backup)
            backup.chmod(0o600)
    shutil.copy2(ROOT / "bin/cove-codex-live.py", target)
    target.chmod(0o755)
    for path, content in ((config_file, updated_config), (hooks_file, json.dumps(updated_hooks, indent=2) + "\n")):
        temporary = path.with_name(path.name + ".cove-live-tmp")
        temporary.write_text(content); temporary.chmod(0o600); temporary.replace(path)
    print("Cove live hooks installed. Existing config/hooks backed up and preserved.")
    print("Codex requires you to review and trust the new definitions in /hooks before they run.")

if __name__ == "__main__":
    main()
