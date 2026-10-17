import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import os
import sys
import http.server
import threading

ROOT = Path(__file__).resolve().parents[2]
def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module); return module
live = load("live", "bin/cove-codex-live.py")
setup = load("setup", "scripts/connect-codex-live.py")

class LiveHookTests(unittest.TestCase):
    def event(self, name, **extra):
        return live.activity({"session_id": "thread-1", "hook_event_name": name, "cwd": "/work/Cove", **extra})
    def test_full_lifecycle_uses_one_activity(self):
        events = [self.event(n) for n in ("UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse", "Stop")]
        self.assertEqual([e["kind"] for e in events], ["running", "running", "attention", "running", "done"])
        self.assertEqual({e["id"] for e in events}, {"codex:thread-1"})
        self.assertTrue(all(e["silent"] and e["source"] == "codex" for e in events))
    def test_private_contents_are_not_forwarded(self):
        e = self.event("PreToolUse", tool_name="Bash", prompt="private prompt", transcript_path="/secret/chat",
                       tool_input={"command": "secret token"}, tool_result="private answer")
        output = json.dumps(e)
        for secret in ["private prompt", "/secret/chat", "secret token", "private answer"]:
            self.assertNotIn(secret, output)
        self.assertEqual(e["phase"], "Running a command")
        self.assertEqual(e["title"], "Cove")
    def test_interrupt_and_close_do_not_stay_running(self):
        self.assertEqual(self.event("Interrupt")["phase"], "Interrupted")
        self.assertEqual(self.event("SessionEnd")["kind"], "clear")
    def test_missing_or_unknown_events_are_ignored(self):
        self.assertIsNone(live.activity({"hook_event_name": "Stop"}))
        self.assertIsNone(self.event("Unrecognized"))
    def test_enable_feature_preserves_existing_configuration(self):
        import tomllib
        for text in ['model = "test"\n[features]\nother = true\n', '[features]\nhooks = false\n[project]\nvalue = 1\n', 'features.hooks = false\n']:
            result = setup.enable_hooks(text)
            self.assertTrue(tomllib.loads(result)["features"]["hooks"])
            self.assertEqual(setup.enable_hooks(result), result)
    def test_merge_preserves_other_hooks_and_is_idempotent(self):
        existing = {"description": "My hooks", "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "my-custom-hook"}]}]}}
        output = setup.merge_hooks(existing, "python3 live.py")
        self.assertEqual(output["hooks"]["Stop"][0], existing["hooks"]["Stop"][0])
        self.assertEqual(output["description"], "My hooks")
        self.assertEqual(setup.merge_hooks(output, "python3 live.py"), output)
    def test_invalid_configs_fail_before_install(self):
        with self.assertRaises(ValueError): setup.merge_hooks({"hooks": []}, "live")
        with self.assertRaises(ValueError): setup.enable_hooks('features = { other = true }')
    def test_helper_posts_to_loopback_and_exits_quietly(self):
        received = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                self.send_response(200); self.end_headers()
            def log_message(self, *args): pass
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            env = dict(os.environ, COVE_PORT=str(server.server_port))
            result = subprocess.run([sys.executable, str(ROOT/'bin/cove-codex-live.py')],
                input=json.dumps({'session_id':'test-thread','cwd':'/work/Cove','hook_event_name':'Stop'}),
                env=env, text=True, capture_output=True, timeout=2)
            self.assertEqual(result.returncode, 0); self.assertEqual(result.stdout, '')
            self.assertEqual(received[0]['kind'], 'done')
        finally: server.shutdown(); server.server_close()
    def test_install_preserves_custom_hooks_and_backs_up_configuration(self):
        import tomllib
        with tempfile.TemporaryDirectory() as folder:
            config = Path(folder)/'config'; binaries = Path(folder)/'bin'; config.mkdir()
            (config/'config.toml').write_text('notify = ["other-program"]\n[features]\nother = true\n')
            custom = {'hooks':{'Stop':[{'hooks':[{'type':'command','command':'my-hook'}]}]}}
            (config/'hooks.json').write_text(json.dumps(custom))
            args = [sys.executable, str(ROOT/'scripts/connect-codex-live.py'), '--install', '--config-dir', str(config), '--bin-dir', str(binaries)]
            subprocess.run(args, check=True, capture_output=True)
            self.assertEqual(tomllib.loads((config/'config.toml').read_text())['notify'], ['other-program'])
            installed = json.loads((config/'hooks.json').read_text())
            self.assertEqual(installed['hooks']['Stop'][0], custom['hooks']['Stop'][0])
            self.assertEqual(len(list(config.glob('*.cove-live-backup-*'))), 2)
            subprocess.run(args, check=True, capture_output=True)
            self.assertEqual(json.loads((config/'hooks.json').read_text()), installed)

if __name__ == "__main__": unittest.main()
