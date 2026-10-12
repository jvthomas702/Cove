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

    // MARK: Claude Code approvals
    /// "smart": show permission prompts in the notch unless the terminal running Claude is in front,
    /// the screen is locked, or you've been idle a while. "always": always use the notch. "off": never.
    var approvals: String = "smart"
    /// Seconds to wait for a click before handing the prompt back to the terminal.
    var approvalTimeout: Double = 90
    /// In "smart" mode, skip the notch if there has been no keyboard/mouse input for this many minutes.
    var approvalIdleMinutes: Double = 5

    // MARK: Calendar & due dates
    var calendar: Bool = true
    /// Show "Class in 12 min" beside the notch when an event starts within this many minutes.
    var countdownMinutes: Int = 30
    /// Heads-up banner this many minutes before an event starts (0 = off).
    var meetingAlertMinutes: Int = 5
    /// Calendars whose events are assignment due dates (e.g. a subscribed D2L/Canvas feed).
    /// Calendars named like Canvas, D2L, Brightspace, Gradescope or "Assignments" are detected automatically.
    var assignmentCalendars: [String] = []
    /// Reminders lists to read due dates from (empty = all lists).
    var reminderLists: [String] = []
    /// How far ahead the "Due soon" list looks.
    var dueLookaheadDays: Int = 7
    /// Banners when something is due in this many hours.
    var dueAlertHours: [Double] = [24, 1]
    /// Calendars to ignore entirely (e.g. "Birthdays", "US Holidays").
    var ignoreCalendars: [String] = ["Birthdays", "US Holidays", "Siri Suggestions"]

    // MARK: Screenshots
    /// Put every new screenshot on the shelf.
    var screenshotsToShelf: Bool = true

    // MARK: Volume / brightness HUD
    /// "replace": Cove handles the volume/brightness keys and hides the system pop-up (needs Accessibility).
    /// "passive": show Cove's HUD next to the system one. "off": no HUD.
    var hud: String = "replace"
    var hudSeconds: Double = 1.4

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
        approvals = value(.approvals, d.approvals)
        approvalTimeout = value(.approvalTimeout, d.approvalTimeout)
        approvalIdleMinutes = value(.approvalIdleMinutes, d.approvalIdleMinutes)
        calendar = value(.calendar, d.calendar)
        countdownMinutes = value(.countdownMinutes, d.countdownMinutes)
        meetingAlertMinutes = value(.meetingAlertMinutes, d.meetingAlertMinutes)
        assignmentCalendars = value(.assignmentCalendars, d.assignmentCalendars)
        reminderLists = value(.reminderLists, d.reminderLists)
        dueLookaheadDays = value(.dueLookaheadDays, d.dueLookaheadDays)
        dueAlertHours = value(.dueAlertHours, d.dueAlertHours)
        ignoreCalendars = value(.ignoreCalendars, d.ignoreCalendars)
        screenshotsToShelf = value(.screenshotsToShelf, d.screenshotsToShelf)
        hud = value(.hud, d.hud)
        hudSeconds = value(.hudSeconds, d.hudSeconds)
    }

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/cove", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("config.json") }

    /// Loads the config, writing a commented-by-example default file on first launch.
    static func load() -> CoveConfig {
        if let data = try? Data(contentsOf: fileURL) {
            do {
                let config = try JSONDecoder().decode(CoveConfig.self, from: data)
                // After an update, write newly added settings into the file so they're discoverable.
                if let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                   let full = try? JSONEncoder().encode(config),
                   let fullKeys = (try? JSONSerialization.jsonObject(with: full)) as? [String: Any],
                   Set(fullKeys.keys).subtracting(existing.keys).isEmpty == false {
                    save(config)
                }
                return config
            } catch {
                NSLog("Cove: config.json could not be parsed (\(error)); using defaults")
                return CoveConfig()
            }
        }
        let config = CoveConfig()
        save(config)
        return config
    }

    static func save(_ config: CoveConfig) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(config).write(to: fileURL)
        } catch {
            NSLog("Cove: could not write config: \(error)")
        }
    }
}
