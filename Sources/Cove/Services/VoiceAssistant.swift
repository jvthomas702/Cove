import AppKit
import AVFoundation
import Combine

/// One event from `claude -p --output-format stream-json --verbose --include-partial-messages`.
enum ClaudeStreamEvent: Equatable {
    /// The session's id (from `system/init`), so the next request can continue it.
    case session(String)
    /// A piece of the reply as it's written.
    case text(String)
    /// Claude started using a tool ("Read", "Bash", "Edit"…).
    case tool(String)
    /// The run finished. `denied` lists tools that needed a permission nobody could give.
    case result(text: String, sessionID: String?, isError: Bool, denied: [String])
}

/// How a spoken request runs through Claude Code.
enum VoiceCommand {
    /// Added to Claude's system prompt so spoken answers stay short and readable in the island.
    static let style = """
    The user spoke this request to Cove, a Mac menu bar app, and reads your reply in a small panel \
    (it may also be read aloud). Answer in a few short, plain sentences without Markdown headings, tables \
    or code blocks unless they ask for code. If you changed files, say which.
    """

    /// The `claude` arguments. The request itself goes on stdin, so it never shows in the process list.
    static func arguments(resume sessionID: String?, canEdit: Bool) -> [String] {
        var arguments = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                         "--append-system-prompt", style]
        if let sessionID { arguments += ["--resume", sessionID] }
        if canEdit { arguments += ["--permission-mode", "acceptEdits"] }
        return arguments
    }

    /// One line of stream-json, or nil for the many lines Cove doesn't need.
    static func parse(_ line: String) -> ClaudeStreamEvent? {
        guard let json = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              let type = json["type"] as? String else { return nil }
        switch type {
        case "system":
            guard json["subtype"] as? String == "init", let id = json["session_id"] as? String else { return nil }
            return .session(id)
        case "stream_event":
            guard let event = json["event"] as? [String: Any] else { return nil }
            if let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let text = delta["text"] as? String {
                return .text(text)
            }
            if event["type"] as? String == "content_block_start",
               let block = event["content_block"] as? [String: Any], block["type"] as? String == "tool_use",
               let name = block["name"] as? String {
                return .tool(name)
            }
            return nil
        case "result":
            let denied = (json["permission_denials"] as? [[String: Any]] ?? []).compactMap { $0["tool_name"] as? String }
            return .result(text: json["result"] as? String ?? "", sessionID: json["session_id"] as? String,
                           isError: json["is_error"] as? Bool ?? (json["subtype"] as? String != "success"),
                           denied: denied)
        default:
            return nil
        }
    }

    /// "Reading", "Searching", "Running a command"… for the line under the request.
    static func describe(tool: String) -> String {
        switch tool {
        case "Read": return "Reading files"
        case "Grep", "Glob", "LS": return "Searching"
        case "Bash": return "Running a command"
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing files"
        case "WebSearch", "WebFetch": return "Looking it up"
        case "Task", "Agent": return "Working on it"
        default: return "Using \(tool)"
        }
    }
}

/// A running `claude -p`, reading its stream line by line. One reader handles stdout in order and only
/// then reports the exit, so the result line always arrives before `onExit`. Both callbacks come from a
/// background queue; callers hop to the main thread themselves.
final class ClaudeRun: @unchecked Sendable {
    private let process = Process()
    private let lock = NSLock()
    private var pending = Data()
    private var errorOutput = Data()

    init(executable: URL, arguments: [String], folder: URL, prompt: String,
         onEvent: @escaping @Sendable (ClaudeStreamEvent) -> Void,
         onExit: @escaping @Sendable (Int32, String) -> Void) throws {
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = ClaudeCLI.environment()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(Data(prompt.utf8))
        try? input.fileHandleForWriting.close()

        // stderr drains on its own so a chatty CLI can't fill the pipe and stall.
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            let data = errors.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errorOutput = data; lock.unlock()
            drained.leave()
        }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let handle = output.fileHandleForReading
            while true {
                let data = handle.availableData   // blocks until there's output; empty at the end
                if data.isEmpty { break }
                lines(adding: data).compactMap(VoiceCommand.parse).forEach(onEvent)
            }
            flush().compactMap(VoiceCommand.parse).forEach(onEvent)
            process.waitUntilExit()
            drained.wait()
            lock.lock(); let message = String(decoding: errorOutput, as: UTF8.self); lock.unlock()
            onExit(process.terminationStatus, message)
        }
    }

    /// Ends the turn (SIGINT, so Claude Code records it cleanly rather than leaving it half done).
    func cancel() {
        if process.isRunning { process.interrupt() }
    }

    private func lines(adding data: Data) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }

    private func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard !pending.isEmpty else { return [] }
        let last = String(decoding: pending, as: UTF8.self)
        pending.removeAll()
        return [last]
    }
}

/// Hold fn, talk, let go: Cove hears you, asks Claude Code, and shows the answer in the island as it's
/// written. Talking again within a few minutes continues the same conversation.
@MainActor
final class VoiceAssistant: ObservableObject {
    enum Phase: Equatable {
        case idle
        case listening
        case thinking
        case answered
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var reply = ""
    /// What Claude is doing right now ("Reading files"), while it works.
    @Published private(set) var activity: String?
    @Published private(set) var level: Double = 0
    /// Tools Claude wanted but couldn't use without asking; offered in Terminal instead.
    @Published private(set) var denied: [String] = []
    @Published private(set) var sessionID: String?

    /// Called whenever the island's size or presentation may change.
    var onChange: (() -> Void)?
    var config: () -> CoveConfig = { CoveConfig() }
    var resolveExecutable: () -> URL? = { AgentLauncher.findExecutable(.claude) }
    var openInTerminal: (URL, @escaping (Error?) -> Void) -> Void = AgentLauncher.openInTerminal

    /// How long a conversation stays open for a follow-up.
    static let followUpWindow: TimeInterval = 5 * 60

    private let listener = SpeechListener()
    private var run: ClaudeRun?
    private var answeredAt: Date?
    private var folderUsed: URL?
    private let speaker = AVSpeechSynthesizer()
    private var dismissWork: DispatchWorkItem?
    private var hovering = false

    var isActive: Bool { phase != .idle }

    init() {
        listener.onTranscript = { [weak self] text in self?.transcript = text }
        listener.onLevel = { [weak self] level in self?.level = level }
    }

    /// The folder Claude works in: the one chosen in Settings, else your home folder.
    var folder: URL {
        if let path = config().voiceFolder, FileBrowser.isBrowsableFolder(URL(fileURLWithPath: path)) {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: fn

    func begin() {
        dismissWork?.cancel()
        run?.cancel()
        run = nil
        speaker.stopSpeaking(at: .immediate)
        transcript = ""
        reply = ""
        activity = nil
        denied = []
        level = 0
        phase = .listening
        Haptics.tap()
        changed()
        Task { [weak self] in
            let failure = await SpeechListener.authorize()
            guard let self, self.phase == .listening else { return }
            if let failure { self.fail(failure.message); return }
            do { try self.listener.start() } catch let error as SpeechListener.Failure {
                self.fail(error.message)
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    func end() {
        guard phase == .listening else { return }
        phase = .thinking
        activity = "Listening…"
        changed()
        listener.stop { [weak self] text in self?.send(text) }
    }

    func cancel() {
        listener.cancel()
        run?.cancel()
        run = nil
        speaker.stopSpeaking(at: .immediate)
        dismiss()
    }

    func dismiss() {
        dismissWork?.cancel()
        phase = .idle
        level = 0
        changed()
    }

    /// The pointer is over the answer: keep it up while you read.
    func setHovering(_ hovering: Bool) {
        self.hovering = hovering
        if hovering { dismissWork?.cancel() } else if phase == .answered || isFailed { scheduleDismiss(after: 6) }
    }

    // MARK: Claude

    private func send(_ text: String) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { fail("Didn't catch that. Hold fn and try again."); return }
        transcript = request
        guard let executable = resolveExecutable() else {
            fail("Install Claude Code and run `claude auth login` in Terminal first.")
            return
        }
        let resume = answeredAt.map { Date().timeIntervalSince($0) < Self.followUpWindow } == true ? sessionID : nil
        if resume == nil { sessionID = nil }
        let folder = self.folder
        folderUsed = folder
        activity = "Thinking…"
        phase = .thinking
        changed()
        do {
            run = try ClaudeRun(
                executable: executable,
                arguments: VoiceCommand.arguments(resume: resume, canEdit: config().voiceCanEdit),
                folder: folder, prompt: request,
                // The main queue runs these in the order they're sent, so the answer always lands before the exit.
                onEvent: { [weak self] event in DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(event) } } },
                onExit: { [weak self] status, errors in
                    DispatchQueue.main.async { MainActor.assumeIsolated { self?.exited(status: status, errors: errors) } }
                })
        } catch {
            fail("Couldn't start Claude Code: \(error.localizedDescription)")
        }
    }

    private func receive(_ event: ClaudeStreamEvent) {
        guard phase == .thinking else { return }
        switch event {
        case .session(let id):
            sessionID = id
        case .text(let text):
            if reply.isEmpty { activity = nil }
            reply += text
            changed()
        case .tool(let name):
            activity = VoiceCommand.describe(tool: name)
            // A new turn of text follows the tool; keep the earlier text, on its own line.
            if !reply.isEmpty, !reply.hasSuffix("\n") { reply += "\n" }
        case .result(let text, let id, let isError, let denied):
            run = nil
            sessionID = id ?? sessionID
            self.denied = Array(Set(denied)).sorted()
            activity = nil
            if isError {
                fail(text.isEmpty ? "Claude Code couldn't answer." : text)
                return
            }
            let answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !answer.isEmpty { reply = answer }
            answeredAt = Date()
            phase = .answered
            Haptics.notice()
            changed()
            speak(reply)
            scheduleDismiss(after: max(12, min(Double(reply.count) / 15, 45)))
        }
    }

    private func exited(status: Int32, errors: String) {
        guard phase == .thinking else { return }
        run = nil
        let message = errors.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        fail(message.map { $0.hasPrefix("Error: ") ? String($0.dropFirst(7)) : $0 } ?? "Claude Code stopped (exit \(status)).")
    }

    /// Opens the conversation in Terminal with Claude's normal permission prompts, so it can do what it
    /// wasn't allowed to here.
    func continueInTerminal() {
        guard let sessionID, let executable = resolveExecutable(),
              let target = ResumeTarget(agent: .claude, sessionID: sessionID, cwd: (folderUsed ?? folder).path) else { return }
        do {
            let script = try ResumeCommand.prepare(target, text: "Go ahead. You can ask me for permission here.", executable: executable)
            openInTerminal(script) { error in
                if error != nil { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
            }
            dismiss()
        } catch {
            fail(error.localizedDescription)
        }
    }

    func copyReply() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(reply, forType: .string)
    }

    // MARK: Helpers

    private var isFailed: Bool { if case .failed = phase { return true }; return false }

    private func fail(_ message: String) {
        listener.cancel()
        activity = nil
        phase = .failed(message)
        changed()
        scheduleDismiss(after: 8)
    }

    private func speak(_ text: String) {
        guard config().voiceSpeaks, !text.isEmpty else { return }
        speaker.stopSpeaking(at: .immediate)
        speaker.speak(AVSpeechUtterance(string: String(text.prefix(800))))
    }

    private func scheduleDismiss(after seconds: TimeInterval) {
        dismissWork?.cancel()
        guard !hovering else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.phase == .answered || self.isFailed else { return }
                self.dismiss()
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func changed() { onChange?() }
}
