import Foundation

/// Running the `claude` CLI from an app.
enum ClaudeCLI {
    /// The app's environment with the usual install folders first on PATH: apps launched from Finder get a
    /// bare PATH, and an npm-installed `claude` needs node beside it.
    nonisolated static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.npm-global/bin"]
        environment["PATH"] = (extra + [environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        return environment
    }
}

/// A Claude cloud session on claude.ai/code that Cove can message.
struct CloudSession: Codable, Identifiable, Hashable {
    /// `session_…` or `cse_…`, as in the session's claude.ai/code URL.
    let id: String
    var title: String
    var repo: String?
    var lastUsed: Date

    var url: URL { URL(string: "https://claude.ai/code/\(id)")! }
}

/// A message you sent from Cove, kept so the composer can show what the session last heard from you.
struct CloudMessage: Codable, Hashable, Identifiable {
    var id = UUID()
    let text: String
    let sentAt: Date
    var delivered: Bool
}

/// What `claude -p --cloud <id> --output-format json` answered.
enum CloudSendResult: Equatable {
    case sent(url: URL?)
    case failed(String)
}

/// Talks to your Claude cloud sessions through the Claude Code CLI:
/// `claude -p --cloud <session-id> --output-format json`, with the message on stdin.
/// The CLI signs in with your claude.ai account, so Cove stores no tokens. Sessions come from the
/// pull requests cloud sessions open (see `CloudSessionsMonitor`), or from a link you paste.
@MainActor final class CloudAgents: ObservableObject {
    @Published private(set) var sessions: [CloudSession] = []
    @Published var selectedID = "" { didSet { if oldValue != selectedID { status = readyStatus } } }
    @Published var prompt = ""
    /// The "Add a session" field: a claude.ai/code link or a bare session id.
    @Published var linkDraft = ""
    @Published private(set) var status = ""
    @Published private(set) var sending = false
    @Published private(set) var messages: [String: [CloudMessage]] = [:]
    var resolveExecutable: () -> URL? = { AgentLauncher.findExecutable(.claude) }
    /// Runs the CLI: (executable, arguments, stdin) → result. Replaced in tests.
    var runCLI: (URL, [String], String) async -> CloudSendResult = CloudAgents.run
    private let defaults: UserDefaults
    private static let sessionsKey = "cloudAgents.sessions"
    private static let messagesKey = "cloudAgents.messages"
    static let maxSessions = 20

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.sessionsKey),
           let saved = try? JSONDecoder().decode([CloudSession].self, from: data) { sessions = saved }
        if let data = defaults.data(forKey: Self.messagesKey),
           let saved = try? JSONDecoder().decode([String: [CloudMessage]].self, from: data) { messages = saved }
        selectedID = sessions.first?.id ?? ""
        status = readyStatus
    }

    var selected: CloudSession? { sessions.first { $0.id == selectedID } }
    var selectedMessages: [CloudMessage] { messages[selectedID] ?? [] }
    var canSend: Bool {
        selected != nil && !sending && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !prompt.contains("\0")
    }

    private var readyStatus: String {
        if sessions.isEmpty { return "Paste a claude.ai/code session link to talk to it." }
        guard let selected else { return "Choose a cloud session." }
        return "Sends a follow-up to \(selected.title). Replies show on claude.ai."
    }

    // MARK: Sessions

    /// The session id in a claude.ai/code link or pasted text, if there is one.
    nonisolated static func sessionID(in text: String) -> String? {
        guard let range = text.range(of: #"\b(session|cse)_[A-Za-z0-9]{8,64}\b"#, options: .regularExpression) else { return nil }
        return String(text[range])
    }

    /// Adds the session in `linkDraft`. Returns false (with a status) when the text holds no session id.
    @discardableResult
    func addFromDraft() -> Bool {
        guard let id = Self.sessionID(in: linkDraft) else {
            status = "That isn’t a claude.ai/code session link."
            return false
        }
        let existing = sessions.first { $0.id == id }
        note(id: id, title: existing?.title ?? "Cloud session \(id.suffix(6))", repo: existing?.repo)
        selectedID = id
        linkDraft = ""
        status = readyStatus
        return true
    }

    /// Remembers a session (a PR's session link, or one you added), most recent first.
    func note(id: String, title: String, repo: String?, at date: Date = Date()) {
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            var session = sessions.remove(at: index)
            // A PR title beats the placeholder name a pasted link gets.
            if session.title.hasPrefix("Cloud session ") || repo != nil { session.title = title }
            session.repo = repo ?? session.repo
            session.lastUsed = max(session.lastUsed, date)
            sessions.insert(session, at: 0)
        } else {
            sessions.insert(CloudSession(id: id, title: title, repo: repo, lastUsed: date), at: 0)
        }
        if sessions.count > Self.maxSessions {
            let dropped = sessions[Self.maxSessions...].map(\.id)
            sessions.removeLast(sessions.count - Self.maxSessions)
            dropped.forEach { messages.removeValue(forKey: $0) }
        }
        if selectedID.isEmpty { selectedID = id }
        save()
    }

    func remove(_ id: String) {
        sessions.removeAll { $0.id == id }
        messages.removeValue(forKey: id)
        if selectedID == id { selectedID = sessions.first?.id ?? "" }
        status = readyStatus
        save()
    }

    // MARK: Sending

    func send() {
        guard canSend, let session = selected else { return }
        guard let executable = resolveExecutable() else {
            status = "Install Claude Code and run `claude auth login` first. Your draft is saved."
            return
        }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        sending = true
        status = "Sending to \(session.title)…"
        let run = runCLI
        Task { [weak self] in
            let result = await run(executable, ["-p", "--cloud", session.id, "--output-format", "json"], text)
            guard let self else { return }
            self.sending = false
            switch result {
            case .sent:
                if self.prompt.trimmingCharacters(in: .whitespacesAndNewlines) == text { self.prompt = "" }
                self.log(text, to: session.id, delivered: true)
                self.note(id: session.id, title: session.title, repo: session.repo)
                self.status = "Sent to \(session.title). Claude picks it up next."
            case .failed(let reason):
                self.status = "\(reason) Your draft is saved."
            }
        }
    }

    private func log(_ text: String, to id: String, delivered: Bool) {
        var list = messages[id] ?? []
        list.append(CloudMessage(text: text, sentAt: Date(), delivered: delivered))
        messages[id] = Array(list.suffix(10))
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(sessions) { defaults.set(data, forKey: Self.sessionsKey) }
        if let data = try? JSONEncoder().encode(messages) { defaults.set(data, forKey: Self.messagesKey) }
    }

    // MARK: The CLI

    /// Reads the CLI's answer: `{ok, session_id, url}` or `{ok: false, error}` on stdout, or a
    /// configuration error on stderr ("Error: Cloud sessions are disabled…").
    nonisolated static func parse(stdout: Data, stderr: Data, status: Int32) -> CloudSendResult {
        if let json = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] {
            if json["ok"] as? Bool == true { return .sent(url: (json["url"] as? String).flatMap(URL.init(string:))) }
            if let error = json["error"] as? String { return .failed(clean(error)) }
        }
        let message = String(decoding: stderr, as: UTF8.self)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        if let message { return .failed(clean(message)) }
        return status == 0 ? .sent(url: nil) : .failed("Claude Code couldn’t send it (exit \(status)).")
    }

    private nonisolated static func clean(_ message: String) -> String {
        var text = message.hasPrefix("Error: ") ? String(message.dropFirst(7)) : message
        if let range = text.range(of: #"failed to send message to cloud session \S+: "#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        text = text.prefix(1).uppercased() + text.dropFirst()
        return text.hasSuffix(".") ? text : text + "."
    }

    /// Runs `claude` with the message on stdin, so it never shows in the process list. Gives up after a minute.
    nonisolated static func run(_ executable: URL, _ arguments: [String], _ input: String) async -> CloudSendResult {
        await Task.detached(priority: .userInitiated) { () -> CloudSendResult in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = ClaudeCLI.environment()
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = stderr
            do { try process.run() } catch {
                return .failed("Couldn’t start Claude Code: \(error.localizedDescription)")
            }
            let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: watchdog)
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
            // The answer is one short JSON line or one error line, well inside a pipe's buffer.
            let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            watchdog.cancel()
            if process.terminationReason == .uncaughtSignal {
                return .failed("Claude Code didn’t answer within a minute.")
            }
            return parse(stdout: outputData, stderr: errorData, status: process.terminationStatus)
        }.value
    }
}
