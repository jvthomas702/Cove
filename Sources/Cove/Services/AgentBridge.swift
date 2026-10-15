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
            model.agentUpdate(id: id, agent: .claude, title: project, detail: detail,
                              phase: model.config.showToolActivity ? tool : "Working")

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
            let island = self.model
            DispatchQueue.global(qos: .utility).async {
                let summary = transcript.flatMap { TranscriptReader.lastAssistantText(path: $0) }?.oneLine(max: 160)
                Task { @MainActor in
                    island.agentFinished(id: id, agent: .claude, title: project, summary: summary)
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

    nonisolated static func describe(tool: String, input: [String: Any]) -> String {
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

    // MARK: Permission prompts (PermissionRequest hook)
    // cove-claude-permission posts the hook JSON here and waits. We answer with Claude Code's
    // hookSpecificOutput JSON (allow / deny), or an empty body to fall back to the normal terminal prompt.

    func handlePermission(_ exchange: HTTPExchange) {
        guard let obj = (try? JSONSerialization.jsonObject(with: exchange.body)) as? [String: Any] else {
            exchange.respond(200, "")
            return
        }
        let sessionID = obj["session_id"] as? String ?? "default"
        let cwd = obj["cwd"] as? String ?? ""
        let project = cwd.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent
        let tool = obj["tool_name"] as? String ?? "tool"
        let input = obj["tool_input"] as? [String: Any] ?? [:]
        let suggestions = obj["permission_suggestions"] as? [Any]
        let activityID = "claude:\(sessionID)"

        guard model.shouldRouteApproval(activityID: activityID) else {
            exchange.respond(200, "") // terminal handles it as usual
            return
        }

        let (action, preview) = Self.describePermission(tool: tool, input: input)
        let request = ApprovalRequest(
            sessionID: activityID,
            project: project,
            tool: tool,
            action: action,
            preview: preview,
            canAlwaysAllow: !(suggestions?.isEmpty ?? true),
            expiresAt: Date().addingTimeInterval(model.config.approvalTimeout)
        )
        let island = self.model
        exchange.onClientGone = { island.cancelApproval(request.id) }
        island.requestApproval(request) { decision in
            exchange.respond(200, Self.permissionResponse(decision, suggestions: suggestions))
        }
    }

    nonisolated static func permissionResponse(_ decision: ApprovalDecision, suggestions: [Any]?) -> String {
        var body: [String: Any]
        switch decision {
        case .ask:
            return ""
        case .allow:
            body = ["behavior": "allow"]
        case .allowAlways:
            body = ["behavior": "allow"]
            if let suggestions, !suggestions.isEmpty { body["updatedPermissions"] = suggestions }
        case .deny:
            body = ["behavior": "deny", "message": "Denied from the notch (Cove)."]
        }
        let output: [String: Any] = [
            "hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": body] as [String: Any]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: output),
              let text = String(data: data, encoding: .utf8) else { return "" }
        return text
    }

    /// Turns the tool call into a short verb phrase plus a few preview lines (command, diff, file head…).
    nonisolated static func describePermission(tool: String, input: [String: Any]) -> (String, ApprovalPreview) {
        var lines: [(String, ApprovalPreview.Style)] = []
        func file(_ key: String = "file_path") -> String {
            ((input[key] as? String).map { ($0 as NSString).lastPathComponent }) ?? "a file"
        }
        func addBlock(_ text: String?, style: ApprovalPreview.Style, prefix: String = "", limit: Int) {
            guard let text, !text.isEmpty else { return }
            let all = text.components(separatedBy: "\n")
            for line in all.prefix(limit) { lines.append((prefix + line, style)) }
            if all.count > limit { lines.append(("  … \(all.count - limit) more lines", .meta)) }
        }

        let action: String
        switch tool {
        case "Bash":
            action = "run a command"
            if let description = input["description"] as? String, !description.isEmpty { lines.append((description, .meta)) }
            addBlock(input["command"] as? String, style: .code, prefix: "$ ", limit: 6)
        case "Edit":
            action = "edit \(file())"
            addBlock(input["old_string"] as? String, style: .removed, prefix: "- ", limit: 4)
            addBlock(input["new_string"] as? String, style: .added, prefix: "+ ", limit: 4)
        case "MultiEdit":
            action = "edit \(file())"
            let edits = input["edits"] as? [[String: Any]] ?? []
            if let first = edits.first {
                addBlock(first["old_string"] as? String, style: .removed, prefix: "- ", limit: 3)
                addBlock(first["new_string"] as? String, style: .added, prefix: "+ ", limit: 3)
            }
            if edits.count > 1 { lines.append(("+ \(edits.count - 1) more edits", .meta)) }
        case "Write":
            action = FileManager.default.fileExists(atPath: input["file_path"] as? String ?? "") ? "overwrite \(file())" : "create \(file())"
            addBlock(input["content"] as? String, style: .added, prefix: "+ ", limit: 6)
        case "NotebookEdit":
            action = "edit \(file("notebook_path"))"
            addBlock(input["new_source"] as? String, style: .added, prefix: "+ ", limit: 6)
        case "Read":
            action = "read \(file())"
            addBlock(input["file_path"] as? String, style: .code, limit: 1)
        case "WebFetch":
            action = "open a web page"
            addBlock(input["url"] as? String, style: .code, limit: 1)
            addBlock((input["prompt"] as? String)?.oneLine(max: 140), style: .meta, limit: 1)
        case "WebSearch":
            action = "search the web"
            addBlock(input["query"] as? String, style: .code, limit: 1)
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.components(separatedBy: "__")
                let server = parts.count > 1 ? parts[1] : "MCP"
                action = "use \(parts.last ?? tool) (\(server))"
            } else {
                action = "use \(tool)"
            }
            if let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                addBlock(json.oneLine(max: 300), style: .code, limit: 1)
            }
        }

        let trimmed = lines.prefix(9).enumerated().map { index, entry in
            ApprovalPreview.Line(id: index, text: String(entry.0.prefix(180)), style: entry.1)
        }
        return (action, ApprovalPreview(lines: trimmed))
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

/// Signals for "is the person actually at the Mac right now?"
enum SystemState {
    static var screenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// Seconds since the last keyboard or mouse input.
    static var idleSeconds: Double {
        let kinds: [CGEventType] = [.mouseMoved, .keyDown, .leftMouseDown, .scrollWheel]
        return kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? 0
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
