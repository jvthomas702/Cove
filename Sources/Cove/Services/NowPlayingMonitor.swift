import AppKit

/// Reads Now Playing from Spotify and Apple Music via AppleScript.
///
/// The private MediaRemote framework is locked down for third-party apps since macOS 15.4, so asking the
/// players directly is the reliable route. Cove only talks to a player that is already running, so it
/// never launches one, and macOS asks once for Automation permission per player.
final class NowPlayingMonitor {
    var onUpdate: (@MainActor (NowPlaying?) -> Void)?

    private let apps: [String]
    private let queue = DispatchQueue(label: "cove.nowplaying", qos: .utility)
    private var scripts: [String: NSAppleScript] = [:] // only touched on `queue`
    private var timer: Timer?

    private static let names = ["com.spotify.client": "Spotify", "com.apple.Music": "Music"]

    init(apps: [String]) {
        self.apps = apps.filter { Self.names[$0] != nil }
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Runs on the main thread; the AppleScript work happens on `queue`.
    private func tick() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = apps.filter { running.contains($0) }
        guard !candidates.isEmpty else {
            deliver(nil)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            var best: NowPlaying?
            for bundleID in candidates {
                guard let info = self.fetch(bundleID) else { continue }
                if info.isPlaying { best = info; break }
                if best == nil { best = info }
            }
            self.deliver(best)
        }
    }

    private func deliver(_ value: NowPlaying?) {
        Task { @MainActor [weak self] in self?.onUpdate?(value) }
    }

    private func fetch(_ bundleID: String) -> NowPlaying? {
        guard let app = Self.names[bundleID] else { return nil }
        let artwork = bundleID == "com.spotify.client" ? "artwork url of t" : "\"\""
        let source = """
        tell application "\(app)"
            if player state is stopped then return ""
            try
                set t to current track
                return (name of t) & linefeed & (artist of t) & linefeed & (player state as text) & linefeed & (\(artwork))
            on error
                return ""
            end try
        end tell
        """
        guard let output = run(source, key: "\(bundleID).info"), !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "\n")
        guard parts.count >= 3, !parts[0].isEmpty else { return nil }
        return NowPlaying(
            bundleID: bundleID,
            title: parts[0],
            artist: parts[1],
            isPlaying: parts[2].lowercased() == "playing",
            artworkURL: parts.count > 3 ? URL(string: parts[3]) : nil
        )
    }

    /// command: "playpause", "next track", "previous track"
    func send(_ command: String, to bundleID: String) {
        guard let app = Self.names[bundleID] else { return }
        queue.async { [weak self] in
            _ = self?.run("tell application \"\(app)\" to \(command)", key: "\(bundleID).\(command)")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self?.tick() }
        }
    }

    private func run(_ source: String, key: String) -> String? {
        let script: NSAppleScript
        if let cached = scripts[key] {
            script = cached
        } else {
            guard let compiled = NSAppleScript(source: source) else { return nil }
            scripts[key] = compiled
            script = compiled
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result.stringValue : nil
    }
}
