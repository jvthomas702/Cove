# Live Codex activity in Cove

The old `notify` integration runs after a turn completes. It cannot indicate that Codex is working. Desktop Accessibility is useful for ChatGPT, but some Codex app controls are not exposed reliably. Codex lifecycle hooks provide a direct working/tool/waiting/finished signal instead.

Run `python3 scripts/connect-codex-live.py` to preview the exact hook configuration. With approval, run it with `--install`. The installer needs Python 3.11+, preserves existing Codex configuration and other hooks, and makes private backups. It installs a helper in `~/.local/bin`, merges seven lifecycle events into `~/.codex/hooks.json`, and enables `features.hooks` in `~/.codex/config.toml`.

Codex requires the user to review and trust the exact new definitions using `/hooks` in the Codex CLI. The installer does not grant trust or bypass that review. Reload the Codex session after trusting the hooks if the current session still uses its earlier configuration.

The helper sends a session ID, project basename, coarse tool phase and lifecycle status only to Cove's `127.0.0.1` endpoint. It ignores prompt text, tool arguments/results, response contents and transcript paths, does not open transcripts, emits no model context, and never changes tool permission decisions. Cove being closed or unavailable does not block Codex. No Accessibility permission is required for this hook connection.

Choose **AI work** in Cove's Home widget. Working, Running a command, Editing files, Searching, Using an app, Waiting for approval, Finished and Interrupted describe lifecycle/tool events; they do not expose hidden reasoning. The previous completion notifier can remain installed and uses the same activity identity.

Official hook schema and trust requirements: https://learn.chatgpt.com/docs/hooks
