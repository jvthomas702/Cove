import Foundation

/// A finished agent session that can be continued from its done banner.
/// Claude Code hooks carry `session_id` and `cwd`; Codex notify payloads carry `thread-id` and `cwd`.
struct ResumeTarget: Equatable {
    var agent: LaunchAgent
    var sessionID: String
    var cwd: String

    /// Nil unless the id is something the CLI can actually resume and the folder is known.
    init?(agent: LaunchAgent, sessionID: String?, cwd: String?) {
        guard let sessionID, let cwd, Self.isResumable(sessionID), cwd.hasPrefix("/"), !cwd.contains("\0") else { return nil }
        self.agent = agent
        self.sessionID = sessionID
        self.cwd = cwd
    }

    /// Session ids are UUID-like. Anything else (a missing id, Cove's "default" fallback, something that
    /// could read as a flag) is not offered, so the reply never resumes the wrong conversation.
    static func isResumable(_ id: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        return id.count >= 8 && id.count <= 128 && !id.hasPrefix("-") && id != "default"
            && id.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}

/// Builds the Terminal command that continues a session with your reply:
/// `cd <cwd> && claude --resume <id> -- <text>` or `codex resume <id> -- <text>`.
/// Every value is a single-quoted literal, so the reply is never interpreted by the shell.
enum ResumeCommand {
    static func shellLine(_ target: ResumeTarget, text: String, executable: URL) -> String {
        let q = AgentLauncher.quote
        let resume = target.agent == .claude
            ? "\(q(executable.path)) --resume \(q(target.sessionID))"
            : "\(q(executable.path)) resume \(q(target.sessionID))"
        return "cd -- \(q(target.cwd)) && exec \(resume) -- \(q(text))"
    }

    static func validate(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !text.contains("\0") else {
            throw AgentLauncher.LaunchError.message("Type a reply without null characters.")
        }
        return trimmed
    }

    /// A self-deleting `.command` script for Terminal (same approach as starting a new task).
    static func prepare(_ target: ResumeTarget, text: String, executable: URL) throws -> URL {
        let reply = try validate(text)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.cwd, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentLauncher.LaunchError.message("The project folder is gone.")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AgentLauncher.LaunchError.message("Install \(target.agent.rawValue) and sign in from Terminal first.")
        }
        return try AgentLauncher.writeScript(named: "Reply to agent.command") { _ in
            shellLine(target, text: reply, executable: executable)
        }
    }
}
