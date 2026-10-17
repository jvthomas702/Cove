# Existing Codex chats and attention

In AI → Existing chat, choose a local Codex chat by its displayed title, type a prompt, and Send. Cove discovers an existing desktop owner for that exact UUID. It sends a follow-up to an active turn or starts the next turn in an idle, loaded chat. If the chat is not loaded, use Open chat and then Send again. No second app server is started. The existing chat's settings and permission policy remain in charge.

The New task option remains available for new interactive Codex or Claude Code sessions in Terminal. Its draft is separate from the existing-chat draft. ChatGPT-backed conversations and remote Codex hosts are outside this local connector.

The installed desktop currently owns its chats through its private same-user coordination socket rather than the CLI daemon's control socket. `codex queue` targets the shared daemon and cannot safely be substituted for that desktop owner. Cove's isolated compatibility adapter uses the desktop's existing owner-discovery and follower message protocol. This protocol may change in future Codex releases; errors leave the draft intact and advise opening the selected chat. Cove never replays an uncertain submission or resumes a chat in a separate server.

For discovery, Cove reads up to 100 recent, nonarchived local chat IDs, titles and project paths from the local catalog using a read-only SQLite connection. It observes the existing desktop stream, discards transcript/tool contents, and retains runtime type and waiting flags only in memory. It never reads auth credentials, changes Codex configuration, claims chat ownership, or answers permission decisions.

A sustained `waitingOnApproval` or `waitingOnUserInput` state produces one attention transition. Automatic approvals that resolve within 1.5 seconds stay quiet. Resuming clears the sticky attention banner. Desktop runtime state supersedes early lifecycle hooks and delayed completion notifications. When the desktop connection closes, stale attention becomes Status unavailable. Claude notification hooks separately allow only explicit permission/input types and ignore idle/auth/completion notices.

Validation covers duplicate waits, short automatic approvals, user-input waits, resume/completion cleanup, stale completion races, exact UUID and literal text delivery, unchanged permissions, draft preservation and no automatic retry. Native UI fixtures use a fake transport and never send to real chats.

Official references: [Codex CLI queue](https://learn.chatgpt.com/docs/cli/reference), [app-server runtime status](https://learn.chatgpt.com/docs/app-server), [Claude notifications](https://code.claude.com/docs/en/hooks#notification).
