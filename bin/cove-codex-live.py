#!/usr/bin/env python3
"""Codex lifecycle metadata -> Cove. Never reads transcripts or sends prompt/tool contents."""
import json
import os
from pathlib import Path
import sys
import urllib.request

EVENTS = ("UserPromptSubmit", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop", "Interrupt", "SessionEnd")

def activity(payload):
    event = payload.get("hook_event_name")
    session = payload.get("session_id")
    if event not in EVENTS or not isinstance(session, str) or not session:
        return None
    project = Path(str(payload.get("cwd") or "")).name or "Codex"
    kind, phase = "running", "Working"
    if event == "PreToolUse":
        tool = str(payload.get("tool_name", "")).lower()
        if tool in ("bash", "exec_command", "shell", "functions.exec"):
            phase = "Running a command"
        elif tool in ("apply_patch", "edit", "write"):
            phase = "Editing files"
        elif "web" in tool or "search" in tool:
            phase = "Searching"
        elif "cua" in tool:
            phase = "Using an app"
        else:
            phase = "Using a tool"
    elif event == "PermissionRequest":
        kind, phase = "attention", "Waiting for approval"
    elif event == "Stop":
        kind, phase = "done", "Finished"
    elif event == "Interrupt":
        kind, phase = "done", "Interrupted"
    elif event == "SessionEnd":
        kind, phase = "clear", "Session ended"
    return {"id": "codex:" + session[:256], "source": "codex", "app": "com.openai.codex",
            "title": project[:90], "body": "Codex · " + phase, "phase": phase,
            "kind": kind, "silent": True}

def port():
    value = os.environ.get("COVE_PORT")
    if value is None:
        try:
            value = json.loads((Path.home() / ".config/cove/config.json").read_text()).get("port", 7777)
        except (OSError, ValueError, AttributeError):
            value = 7777
    value = int(value)
    if not 1 <= value <= 65535:
        raise ValueError("invalid port")
    return value

def main():
    try:
        payload = json.loads(sys.stdin.read(2 * 1024 * 1024))
        if not isinstance(payload, dict):
            return
        output = activity(payload)
        if output is None:
            return
        request = urllib.request.Request("http://127.0.0.1:%d/event" % port(),
            data=json.dumps(output).encode(), headers={"Content-Type": "application/json"}, method="POST")
        # A closed Cove must never block a Codex turn or change its tool decisions.
        with urllib.request.urlopen(request, timeout=0.3):
            pass
    except (OSError, ValueError, TypeError, AttributeError):
        pass

if __name__ == "__main__":
    main()
