import Foundation

/// Wraps the user's status line, keeping its exact settings for disconnection.
enum ClaudeUsageSetup {
    static var executable: URL { CovePaths.binDir.appendingPathComponent("cove-claude-usage") }
    static var isInstalled: Bool { isInstalled(settingsURL: CovePaths.claudeSettings, executable: executable) }

    static func isInstalled(settingsURL: URL, executable: URL) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let line = settings["statusLine"] as? [String: Any], let command = line["command"] as? String else { return false }
        let bare = command.replacingOccurrences(of: #"^COVE_PORT=\d+ "#, with: "", options: .regularExpression)
        return bare.hasPrefix(AgentLauncher.quote(executable.path) + " -- ")
    }

    static func set(installed: Bool, settingsURL: URL = CovePaths.claudeSettings,
                    executable: URL = ClaudeUsageSetup.executable, bundled: URL? = CovePaths.bundledBin?.appendingPathComponent("cove-claude-usage"), port: UInt16 = 7777) throws {
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        if fm.fileExists(atPath: settingsURL.path) {
            guard let data = try? Data(contentsOf: settingsURL),
                  let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentLauncher.LaunchError.message("Claude settings aren't valid JSON. Cove left them unchanged.")
            }
            settings = parsed
        }
        let backup = settingsURL.appendingPathExtension("cove-usage-statusline")
        let connected = isInstalled(settingsURL: settingsURL, executable: executable)
        if installed {
            guard !connected else { return }
            guard let bundled, fm.fileExists(atPath: bundled.path) else {
                throw AgentLauncher.LaunchError.message("This copy of Cove is missing the Claude usage helper. Rebuild the app.")
            }
            try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
            if executable != bundled {
                let script = try Data(contentsOf: bundled)
                try script.write(to: executable, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            }
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let saved = try JSONSerialization.data(withJSONObject: ["previous": settings["statusLine"] ?? NSNull()])
            try saved.write(to: backup, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            let prior = settings["statusLine"] as? [String: Any]
            var line = prior ?? [:]
            line["type"] = "command"
            // The previous command is one literal argument, evaluated only by the helper as it was before.
            line["command"] = AgentLauncher.quote(executable.path) + " -- " + AgentLauncher.quote(prior?["command"] as? String ?? "")
            if port != 7777 { line["command"] = "COVE_PORT=\(port) " + (line["command"] as! String) }
            settings["statusLine"] = line
        } else {
            guard connected else { return }
            guard let data = try? Data(contentsOf: backup),
                  let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AgentLauncher.LaunchError.message("The original Claude status line backup is unavailable. Cove left settings unchanged.")
            }
            settings["statusLine"] = saved["previous"] is NSNull ? nil : saved["previous"]
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }
}
