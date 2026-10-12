import Foundation

/// User settings, stored as JSON at ~/.config/cove/config.json.
/// Every key is optional in the file; anything missing falls back to the default below.
struct CoveConfig: Codable {
    /// Local port for the event API (127.0.0.1 only). Restart Cove after changing it.
    var port: UInt16 = 7777
    /// Play sounds for agent completions, attention requests and failures.
    var sounds: Bool = true
    var doneSound: String = "Glass"
    var attentionSound: String = "Ping"
    /// How long ordinary banners stay up.
    var bannerSeconds: Double = 4.5
    /// Expand the island when the pointer rests on it.
    var hoverToExpand: Bool = true
    var hoverDelay: Double = 0.12
    /// Mirror macOS notifications into the island (needs Full Disk Access).
    var mirrorNotifications: Bool = true
    /// Bundle IDs whose notifications should never be mirrored.
    var ignoreApps: [String] = []
    /// Notifications containing any of these words get the amber "attention" style and stay until clicked.
    var highlightKeywords: [String] = ["interview", "offer", "deadline", "congratulations", "accepted", "action required"]
    /// Show what Claude Code is doing right now (editing a file, running a command…).
    var showToolActivity: Bool = true
    /// Media apps Cove watches for Now Playing, in priority order.
    var mediaApps: [String] = ["com.spotify.client", "com.apple.Music"]
    /// Charging and low-battery banners.
    var batteryAlerts: Bool = true
    /// Focus timer presets, in minutes.
    var focusMinutes: [Int] = [25, 50, 90]

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CoveConfig()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        port = value(.port, d.port)
        sounds = value(.sounds, d.sounds)
        doneSound = value(.doneSound, d.doneSound)
        attentionSound = value(.attentionSound, d.attentionSound)
        bannerSeconds = value(.bannerSeconds, d.bannerSeconds)
        hoverToExpand = value(.hoverToExpand, d.hoverToExpand)
        hoverDelay = value(.hoverDelay, d.hoverDelay)
        mirrorNotifications = value(.mirrorNotifications, d.mirrorNotifications)
        ignoreApps = value(.ignoreApps, d.ignoreApps)
        highlightKeywords = value(.highlightKeywords, d.highlightKeywords)
        showToolActivity = value(.showToolActivity, d.showToolActivity)
        mediaApps = value(.mediaApps, d.mediaApps)
        batteryAlerts = value(.batteryAlerts, d.batteryAlerts)
        focusMinutes = value(.focusMinutes, d.focusMinutes)
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cove", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Loads the config, writing a commented-by-example default file on first launch.
    static func load() -> CoveConfig {
        let fm = FileManager.default
        if let data = try? Data(contentsOf: fileURL) {
            do {
                return try JSONDecoder().decode(CoveConfig.self, from: data)
            } catch {
                NSLog("Cove: config.json could not be parsed (\(error)); using defaults")
                return CoveConfig()
            }
        }
        let config = CoveConfig()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: fileURL)
        } catch {
            NSLog("Cove: could not write default config: \(error)")
        }
        return config
    }
}
