import AppKit
import Combine

enum LaunchAgent: String, CaseIterable {
    case codex = "Codex", claude = "Claude Code", claudeCloud = "Claude (cloud)"
    var executable: String { self == .codex ? "codex" : "claude" }
    /// Runs on claude.ai's machines (`claude --cloud`) instead of in the folder on this Mac.
    var isCloud: Bool { self == .claudeCloud }
}

/// Starts the installed interactive CLI. Prompts stay literal arguments; agent permissions remain intact.
@MainActor final class AgentLauncher: ObservableObject {
    @Published var prompt = ""
    @Published var agent: LaunchAgent = .codex
    @Published var folder: URL?
    @Published private(set) var status = "Tasks open in Terminal with your agent’s normal permissions."
    @Published private(set) var launching = false
    var openCommand: (URL, @escaping (Error?) -> Void) -> Void = AgentLauncher.openInTerminal
    var resolveExecutable: (LaunchAgent) -> URL? = AgentLauncher.findExecutable

    /// Opens a `.command` script in Terminal, where the agent keeps its normal interactive session.
    nonisolated static func openInTerminal(_ url: URL, completion: @escaping (Error?) -> Void) {
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            completion(LaunchError.message("Terminal is unavailable.")); return
        }
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            completion(error)
        }
    }

    nonisolated static func findExecutable(_ agent: LaunchAgent) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = [home.appendingPathComponent(".local/bin"), URL(fileURLWithPath: "/opt/homebrew/bin"),
                           URL(fileURLWithPath: "/usr/local/bin"), home.appendingPathComponent(".npm-global/bin")]
        return directories.map { $0.appendingPathComponent(agent.executable) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    enum LaunchError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }

    var canLaunch: Bool { folder != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !launching }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Choose project"
        panel.directoryURL = folder
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.folder = url
        }
    }

    func launch() {
        guard canLaunch, let folder else { return }
        guard let executable = resolveExecutable(agent) else {
            status = "Install \(agent.rawValue) and sign in from Terminal first."; return
        }
        let text = prompt
        do {
            let cloud = agent.isCloud
            let script = try Self.prepareCommand(executable: executable, folder: folder, prompt: text, cloud: cloud)
            launching = true
            let name = agent.rawValue
            openCommand(script) { [weak self] error in
                Task { @MainActor in
                    guard let self else { return }
                    self.launching = false
                    if let error {
                        try? FileManager.default.removeItem(at: script.deletingLastPathComponent())
                        self.status = "Couldn’t open \(name): \(error.localizedDescription)"
                    } else {
                        if self.prompt == text { self.prompt = "" }
                        self.status = cloud
                            ? "Starting a cloud session from Terminal. Its link appears there; message it from Cloud."
                            : "Opened \(name) in Terminal. Connected activity appears above."
                    }
                }
            }
        } catch { status = error.localizedDescription }
    }

    /// `--cloud` reads the task as its value, so a task that starts with "-" would read as a flag.
    nonisolated static func cloudTask(_ prompt: String) -> String {
        let task = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return task.hasPrefix("-") ? "Task: " + task : task
    }

    nonisolated static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// `cloud` starts a claude.ai cloud session for the folder's GitHub repo (`claude --cloud <task>`)
    /// instead of an interactive session on this Mac.
    static func prepareCommand(executable: URL, folder: URL, prompt: String, cloud: Bool = false) throws -> URL {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !prompt.contains("\0") else {
            throw LaunchError.message("Enter a task without null characters.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LaunchError.message("Choose an existing project folder.")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw LaunchError.message("The selected agent is no longer installed.")
        }
        let run = cloud
            ? "exec \(quote(executable.path)) --cloud \(quote(cloudTask(prompt)))"
            : "exec \(quote(executable.path)) -- \(quote(prompt))"
        return try writeScript(named: "Start agent.command") { _ in
            """
            cd -- \(quote(folder.path)) || exit 1
            \(run)
            """
        }
    }

    /// Writes a private, self-deleting zsh script. The prompt never outlives the Terminal launch:
    /// the script removes itself and its unique directory before running `commands`.
    nonisolated static func writeScript(named name: String, commands: (URL) -> String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cove-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let script = directory.appendingPathComponent(name)
        let source = """
        #!/bin/zsh -l
        /bin/rm -- "$0"
        /bin/rmdir -- \(quote(directory.path))
        \(commands(directory))

        """
        do {
            try Data(source.utf8).write(to: script, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
            return script
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }
}
