import AppKit

/// Translates Claude Code hook payloads and Codex notify payloads into island activity.
@MainActor
final class AgentBridge {
    private let model: IslandModel

    init(model: IslandModel) {
        self.model = model
    }

    // MARK: Claude Code
    // Hook events used: UserPromptSubmit (start), PreToolUse (live detail), Notification (needs you),
    // Stop (done), SessionEnd (cleanup). See scripts/install-hooks.sh.

    func handleClaude(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let event = obj["hook_event_name"] as? String ?? ""
        let sessionID = obj["session_id"] as? String ?? "default"
        let cwd = obj["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent
        let id = "claude:\(sessionID)"

        switch event {
        case "UserPromptSubmit":
            let prompt = (obj["prompt"] as? String ?? "").oneLine(max: 90)
            model.agentStarted(
                id: id, agent: .claude, title: project,
                detail: prompt.isEmpty ? "Thinking…" : prompt,
                ownerApp: NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            )

        case "PreToolUse":
            let tool = obj["tool_name"] as? String ?? "tool"
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            let detail = model.config.showToolActivity ? Self.describe(tool: tool, input: input) : "Working…"
            model.agentUpdate(id: id, agent: .claude, title: project, detail: detail)

        case "Notification":
            let message = obj["message"] as? String ?? "Claude needs your attention"
            // Claude also nags after ~60s idle at the prompt; we already said it was done.
            if message.range(of: "waiting for your input", options: .caseInsensitive) != nil,
               let current = model.activity(id), !current.isLive {
                return
            }
            model.agentAttention(id: id, agent: .claude, title: project, message: message.oneLine(max: 140))

        case "Stop":
            let transcript = obj["transcript_path"] as? String
            let model = self.model
            DispatchQueue.global(qos: .utility).async {
                let summary = transcript.flatMap { TranscriptReader.lastAssistantText(path: $0) }?.oneLine(max: 160)
                Task { @MainActor in
                    model.agentFinished(id: id, agent: .claude, title: project, summary: summary)
                }
            }

        case "SessionEnd":
            if let current = model.activity(id), current.isLive {
                model.removeActivity(id)
            }

        default:
            break
        }
    }

    static func describe(tool: String, input: [String: Any]) -> String {
        func file(_ key: String = "file_path") -> String {
            ((input[key] as? String).map { ($0 as NSString).lastPathComponent }) ?? "a file"
        }
        switch tool {
        case "Bash":
            if let command = input["command"] as? String { return "$ " + command.oneLine(max: 70) }
            return "Running a command"
        case "Edit", "MultiEdit": return "Editing \(file())"
        case "Write": return "Writing \(file())"
        case "Read": return "Reading \(file())"
        case "NotebookEdit": return "Editing \(file("notebook_path"))"
        case "Grep", "Glob": return "Searching the code"
        case "WebSearch": return "Searching the web"
        case "WebFetch": return "Reading a web page"
        case "Task", "Agent": return "Running a subagent"
        case "TodoWrite": return "Updating the plan"
        default:
            if tool.hasPrefix("mcp__") {
                let name = tool.components(separatedBy: "__").last ?? tool
                return "Using \(name.replacingOccurrences(of: "_", with: " "))"
            }
            return "Using \(tool)"
        }
    }

    // MARK: Codex
    // Codex runs `notify = [...]` from ~/.codex/config.toml with the event JSON as its last argument.

    func handleCodex(_ data: Data) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        guard (obj["type"] as? String) == "agent-turn-complete" else { return }
        let cwd = obj["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Codex" : (cwd as NSString).lastPathComponent
        let thread = obj["thread-id"] as? String ?? obj["turn-id"] as? String ?? "codex"
        let summary = (obj["last-assistant-message"] as? String)?.oneLine(max: 160)
        model.agentFinished(id: "codex:\(thread)", agent: .codex, title: project, summary: summary)
    }
}

/// Pulls the last thing Claude said out of the session transcript (JSONL) for the "done" banner.
enum TranscriptReader {
    static func lastAssistantText(path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 256 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }

        for line in text.split(separator: "\n").reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  (obj["type"] as? String) == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let texts = content.compactMap { part -> String? in
                (part["type"] as? String) == "text" ? part["text"] as? String : nil
            }
            let joined = texts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { return joined }
        }
        return nil
    }
}
