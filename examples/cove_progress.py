"""
Push live progress from Python (training loops, sweeps, sims) to the Cove notch.

Zero dependencies. If Cove isn't running, every call silently does nothing.

    from cove_progress import Cove

    cove = Cove("HDC training")            # shows a live activity in the notch
    for epoch in range(1, epochs + 1):
        acc = train_one_epoch()
        cove.progress(epoch / epochs, f"epoch {epoch}/{epochs} · acc {acc:.3f}")
    cove.done(f"best acc {best:.3f}")      # green banner + sound

When the script runs under `cove-run`, it reuses that activity automatically.
"""
from __future__ import annotations

import json
import os
import urllib.request


class Cove:
    def __init__(self, title: str, source: str = "command", port: int | None = None):
        self.title = title
        self.source = source
        self.port = port or int(os.environ.get("COVE_PORT", "7777"))
        self.id = os.environ.get("COVE_ACTIVITY_ID", f"py-{os.getpid()}")
        self.progress(None, "Starting…")

    def _post(self, payload: dict) -> None:
        payload = {"id": self.id, "title": self.title, "source": self.source, **payload}
        request = urllib.request.Request(
            f"http://127.0.0.1:{self.port}/event",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        try:
            urllib.request.urlopen(request, timeout=0.5).read()
        except Exception:
            pass  # never let notifications break a training run

    def progress(self, fraction: float | None, detail: str = "") -> None:
        payload = {"kind": "running", "body": detail}
        if fraction is not None:
            payload["progress"] = max(0.0, min(1.0, float(fraction)))
        self._post(payload)

    def done(self, summary: str = "") -> None:
        self._post({"kind": "done", "body": summary})

    def failed(self, reason: str = "") -> None:
        self._post({"kind": "error", "body": reason})

    def attention(self, message: str) -> None:
        self._post({"kind": "attention", "body": message})


if __name__ == "__main__":
    import time

    cove = Cove("Demo sweep")
    for step in range(1, 11):
        time.sleep(0.6)
        cove.progress(step / 10, f"config {step}/10")
    cove.done("best: dim=10000, acc 0.947")
