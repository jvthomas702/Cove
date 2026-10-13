import AppKit
import ApplicationServices
import EventKit
import Foundation
import os

let coveLog = Logger(subsystem: "app.cove.island", category: "app")

/// Where Cove keeps things on disk.
enum CovePaths {
    static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var binDir: URL { home.appendingPathComponent(".local/bin", isDirectory: true) }
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Cove", isDirectory: true)
    }
    static var extensionDir: URL { support.appendingPathComponent("browser-extension", isDirectory: true) }
    static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }

    /// Resources bundled inside Cove.app (scripts/build-app.sh copies them in).
    static var bundledBin: URL? { Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true) }
    static var bundledExtension: URL? { Bundle.main.resourceURL?.appendingPathComponent("extension", isDirectory: true) }

    static let tools = ["cove-notify", "cove-run", "cove-claude-hook", "cove-claude-permission", "cove-codex-notify"]
}

// MARK: - Command-line tools

enum CLIInstaller {
    static var isInstalled: Bool {
        CovePaths.tools.allSatisfy { FileManager.default.isExecutableFile(atPath: CovePaths.binDir.appendingPathComponent($0).path) }
    }

    static var isOnPath: Bool {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if path.split(separator: ":").contains(where: { String($0) == CovePaths.binDir.path }) { return true }
        // Apps launched from Finder don't see the shell PATH; check the user's zsh config instead.
        let zshrc = CovePaths.home.appendingPathComponent(".zshrc")
        let text = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
        return text.contains(".local/bin")
    }

    /// Copies the bundled tools to ~/.local/bin and adds that folder to the zsh PATH if needed.
    static func install() throws {
        guard let source = CovePaths.bundledBin, FileManager.default.fileExists(atPath: source.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "This copy of Cove doesn't include the command-line tools. Run scripts/install.sh instead."])
        }
        let fm = FileManager.default
        try fm.createDirectory(at: CovePaths.binDir, withIntermediateDirectories: true)
        for tool in CovePaths.tools {
            let target = CovePaths.binDir.appendingPathComponent(tool)
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.copyItem(at: source.appendingPathComponent(tool), to: target)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        if !isOnPath {
            let zshrc = CovePaths.home.appendingPathComponent(".zshrc")
            let line = "\n# Added by Cove\nexport PATH=\"$HOME/.local/bin:$PATH\"\n"
            if let handle = try? FileHandle(forWritingTo: zshrc) {
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(line.utf8))
                try handle.close()
            } else {
                try line.write(to: zshrc, atomically: true, encoding: .utf8)
            }
        }
    }
}

// MARK: - Claude Code hooks

enum ClaudeHooks {
    static var hookCommand: String { CovePaths.binDir.appendingPathComponent("cove-claude-hook").path }
    static var permissionCommand: String { CovePaths.binDir.appendingPathComponent("cove-claude-permission").path }

    /// Event → (command, timeout, matcher)
    private static var wanted: [(String, String, Int, String?)] {
        [
            ("UserPromptSubmit", hookCommand, 5, nil),
            ("PreToolUse", hookCommand, 5, "*"),
            ("Notification", hookCommand, 5, nil),
            ("Stop", hookCommand, 5, nil),
            ("SessionEnd", hookCommand, 5, nil),
            ("PermissionRequest", permissionCommand, 120, "*"),
        ]
    }

    static var isInstalled: Bool {
        guard let text = try? String(contentsOf: CovePaths.claudeSettings, encoding: .utf8) else { return false }
        return text.contains("cove-claude-hook") && text.contains("cove-claude-permission")
    }

    static var claudeCodeExists: Bool {
        FileManager.default.fileExists(atPath: CovePaths.home.appendingPathComponent(".claude").path)
    }

    /// Adds (or removes) Cove's hooks in ~/.claude/settings.json, keeping everything else, with a backup.
    static func set(installed: Bool) throws {
        let fm = FileManager.default
        let url = CovePaths.claudeSettings
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't valid JSON, so Cove left it alone."])
            }
            settings = parsed
            try? data.write(to: url.appendingPathExtension("cove-backup"))
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let ours: Set<String> = [hookCommand, permissionCommand]
        for (event, command, timeout, matcher) in wanted {
            var groups = (hooks[event] as? [[String: Any]] ?? []).compactMap { group -> [String: Any]? in
                var group = group
                let kept = (group["hooks"] as? [[String: Any]] ?? []).filter { !ours.contains($0["command"] as? String ?? "") }
                guard !kept.isEmpty else { return nil }
                group["hooks"] = kept
                return group
            }
            if installed {
                var group: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": timeout]]]
                if let matcher { group["matcher"] = matcher }
                groups.append(group)
            }
            hooks[event] = groups.isEmpty ? nil : groups
        }
        settings["hooks"] = hooks.isEmpty ? nil : hooks

        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Codex

enum CodexNotify {
    enum State { case notInstalled, connected, disconnected, otherNotifyProgram }

    static var command: String { CovePaths.binDir.appendingPathComponent("cove-codex-notify").path }

    static var state: State {
        guard FileManager.default.fileExists(atPath: CovePaths.home.appendingPathComponent(".codex").path) else { return .notInstalled }
        let text = (try? String(contentsOf: CovePaths.codexConfig, encoding: .utf8)) ?? ""
        if text.contains("cove-codex-notify") { return .connected }
        if text.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("notify") }) {
            return .otherNotifyProgram
        }
        return .disconnected
    }

    /// `notify` must be a top-level key, so it goes before any [table].
    static func connect() throws {
        let url = CovePaths.codexConfig
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if !existing.isEmpty { try? existing.write(to: url.appendingPathExtension("cove-backup"), atomically: true, encoding: .utf8) }
        try ("notify = [\"\(command)\"]\n" + existing).write(to: url, atomically: true, encoding: .utf8)
    }

    static func disconnect() throws {
        let url = CovePaths.codexConfig
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let kept = text.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.contains("cove-codex-notify") }
        try kept.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Browser extension

enum BrowserExtension {
    static var installedVersion: String? {
        let manifest = CovePaths.extensionDir.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifest),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }

    /// Keeps ~/Library/Application Support/Cove/browser-extension in sync with the copy inside Cove.app.
    @discardableResult
    static func syncFromBundle() -> Bool {
        guard let source = CovePaths.bundledExtension, FileManager.default.fileExists(atPath: source.path) else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: CovePaths.support, withIntermediateDirectories: true)
            if fm.fileExists(atPath: CovePaths.extensionDir.path) { try fm.removeItem(at: CovePaths.extensionDir) }
            try fm.copyItem(at: source, to: CovePaths.extensionDir)
            return true
        } catch {
            coveLog.error("Couldn't copy the browser extension: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    static let browsers: [(name: String, bundleID: String, page: String)] = [
        ("Chrome", "com.google.Chrome", "chrome://extensions"),
        ("Arc", "company.thebrowser.Browser", "arc://extensions"),
        ("Brave", "com.brave.Browser", "brave://extensions"),
        ("Edge", "com.microsoft.edgemac", "edge://extensions"),
    ]

    static var installedBrowser: (name: String, bundleID: String, page: String)? {
        browsers.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// Opens the browser's extensions page and reveals the folder to choose in "Load unpacked".
    static func openSetup() {
        syncFromBundle()
        NSWorkspace.shared.activateFileViewerSelecting([CovePaths.extensionDir])
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(CovePaths.extensionDir.path, forType: .string)
        if let browser = installedBrowser,
           let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser.bundleID),
           let page = URL(string: browser.page) {
            NSWorkspace.shared.open([page], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        }
    }
}

// MARK: - Permissions

enum Permission: String, CaseIterable, Identifiable {
    case calendars, reminders, accessibility, desktop, fullDiskAccess

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calendars: return "Calendars"
        case .reminders: return "Reminders"
        case .accessibility: return "Accessibility"
        case .desktop: return "Desktop folder"
        case .fullDiskAccess: return "Full Disk Access"
        }
    }

    var reason: String {
        switch self {
        case .calendars: return "Next class countdown and heads-ups"
        case .reminders: return "Due dates in the Due soon list"
        case .accessibility: return "Volume and brightness keys show in the notch"
        case .desktop: return "Screenshots drop onto the shelf"
        case .fullDiskAccess: return "Mirror notifications from other apps"
        }
    }

    var symbol: String {
        switch self {
        case .calendars: return "calendar"
        case .reminders: return "checklist"
        case .accessibility: return "speaker.wave.2.fill"
        case .desktop: return "photo.on.rectangle"
        case .fullDiskAccess: return "bell.badge.fill"
        }
    }

    var settingsURL: URL? {
        let anchor: String
        switch self {
        case .calendars: anchor = "Privacy_Calendars"
        case .reminders: anchor = "Privacy_Reminders"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .desktop: anchor = "Privacy_FilesAndFolders"
        case .fullDiskAccess: anchor = "Privacy_AllFiles"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    var isGranted: Bool {
        switch self {
        case .calendars: return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .reminders: return EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        case .accessibility: return AXIsProcessTrusted()
        case .desktop:
            // Probing the folder would pop up macOS's access prompt, so callers use ScreenshotWatcher's result.
            return false
        case .fullDiskAccess:
            return NotificationMirror.candidatePaths.contains { FileHandle(forReadingAtPath: $0) != nil }
        }
    }

    /// Asks macOS (shows the system prompt where one exists), otherwise opens the right Settings pane.
    @MainActor
    func request() async {
        let store = EKEventStore()
        switch self {
        case .calendars:
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try? await store.requestFullAccessToEvents()
                return
            }
        case .reminders:
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                _ = try? await store.requestFullAccessToReminders()
                return
            }
        case .accessibility:
            MediaKeyTap.requestTrust()
        case .desktop:
            break // handled by SettingsController (it asks the screenshot watcher to re-read the folder)
        case .fullDiskAccess:
            break
        }
        if let url = settingsURL { NSWorkspace.shared.open(url) }
    }
}
