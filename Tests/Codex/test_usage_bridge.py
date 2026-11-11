import http.server
import json
import pathlib
import subprocess
import sys
import threading
import unittest


SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "bin" / "cove-claude-usage"


class UsageBridgeTests(unittest.TestCase):
    def test_only_quota_numbers_are_forwarded_and_previous_output_is_preserved(self):
        bodies = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                bodies.append((self.path, json.loads(self.rfile.read(int(self.headers["Content-Length"])))))
                self.send_response(200)
                self.end_headers()

            def log_message(self, *args):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            payload = {"session_id": "private", "transcript_path": "/private/chat.jsonl",
                       "rate_limits": {"five_hour": {"used_percentage": 23.5, "resets_at": 2000000000, "private": "omit"},
                                       "seven_day": {"used_percentage": True}, "other": {"used_percentage": 20}}}
            raw = json.dumps(payload).encode()
            import os
            env = dict(os.environ, COVE_PORT=str(server.server_port))
            result = subprocess.run([sys.executable, str(SCRIPT), "--", "cat"], input=raw, capture_output=True, env=env, timeout=5)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout, raw)
            self.assertEqual(bodies, [("/usage/claude", {"rate_limits": {
                "five_hour": {"used_percentage": 23.5, "resets_at": 2000000000}, "seven_day": {}}})])
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)

    def test_offline_cove_and_invalid_payload_do_not_break_status_line(self):
        import os
        result = subprocess.run([sys.executable, str(SCRIPT), "--", "cat"], input=b"not json", capture_output=True,
                                env=dict(os.environ, COVE_PORT="1"), timeout=5)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"not json")


if __name__ == "__main__":
    unittest.main()
