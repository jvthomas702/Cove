import Foundation

enum IslandTheme: String, Codable, CaseIterable {
    case darkMatte
    /// Green-on-black monospace, like a terminal.
    case terminal
    var title: String { self == .terminal ? "Terminal" : "Black" }
}

/// How buttons are drawn on the island (the terminal look always uses brackets).
enum ButtonLook: String, Codable, CaseIterable {
    /// Thin accent outline, accent text.
    case outline
    /// Accent text with a soft accent glow, no frame.
    case glow
    /// Filled with a dark accent tint.
    case tinted
    var title: String {
        switch self {
        case .outline: return "Outline"
        case .glow: return "Glow"
        case .tinted: return "Tinted"
        }
    }
}

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
    var hoverDelay: Double = 0.25
    var islandTheme: IslandTheme = .darkMatte
    var buttonLook: ButtonLook = .outline
    /// Which display the island is on: the notch (falls back to the main display), or the one the pointer is on.
    var islandDisplay: IslandDisplay = .notch
    /// Mirror macOS notifications into the island (needs Full Disk Access).
    var mirrorNotifications: Bool = true
    /// Bundle IDs whose notifications should never be mirrored.
    var ignoreApps: [String] = []
    /// Notifications containing any of these words get the amber "attention" style and stay until clicked.
    var highlightKeywords: [String] = ["interview", "offer", "deadline", "congratulations", "accepted", "action required"]
    /// Show what Claude Code is doing right now (editing a file, running a command…).
    var showToolActivity: Bool = true
    /// A "Reply…" field on Claude Code and Codex done banners that continues the same session in Terminal.
    var bannerReplies: Bool = true
    /// Media apps Cove watches for Now Playing, in priority order.
    var mediaApps: [String] = ["com.spotify.client", "com.apple.Music"]
    /// Charging and low-battery banners.
    var batteryAlerts: Bool = true
    /// A brief green battery filling up in the island when the power adapter is plugged in.
    var chargingAnimation: Bool = true
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
    /// Calendar links Cove reads directly (D2L/Canvas subscribe links, Google's secret iCal address, webcal://…).
    /// No Calendar app setup needed. These are private links, so they're never shown in diagnostics.
    var calendarFeeds: [String] = []
    /// Reminders lists to read due dates from (empty = all lists).
    var reminderLists: [String] = []
    /// How far ahead the "Due soon" list looks.
    var dueLookaheadDays: Int = 7
    /// Banners when something is due in this many hours.
    var dueAlertHours: [Double] = [24, 1]
    /// Calendars to ignore entirely (e.g. "Birthdays", "US Holidays").
    var ignoreCalendars: [String] = ["Birthdays", "US Holidays", "Siri Suggestions"]

    /// Banner when an event starts, so you know what's happening now.
    var eventStartAlert: Bool = true

    // MARK: Avatar
    /// Nori, the little avatar that reacts when agents and commands work, finish, fail or need you.
    var buddy: Bool = true
    /// Keep Nori napping beside the notch even when nothing is happening.
    var buddyAlwaysVisible: Bool = true

    // MARK: Screenshots
    /// Put every new screenshot on the shelf.
    var screenshotsToShelf: Bool = true
    /// Keep captures quiet unless the user explicitly asks for a banner.
    var screenshotBanners: Bool = false
    /// Move new screenshots from the Desktop into ~/Pictures/Screenshots, keeping the Desktop clean.
    var screenshotsMoveOffDesktop: Bool = false

    // MARK: Drop zone
    /// Dragging a file onto the island shows two targets: AirDrop and Keep (the shelf).
    var airDropDropZone: Bool = true

    // MARK: Widgets & sports
    var homeWidget: HomeWidget = .auto
    var desktopAIActivity: Bool = true
    var aiWorkInNotch: Bool = true
    var sportsEnabled: Bool = true
    var sportsLeague: SportsLeague = .nfl
    var sportsGameID: String? = nil
    /// "Big games": at least one Top 25 team. Turn off to browse all FBS games.
    var sportsRankedOnly: Bool = true
    var sportsFavoriteTeams: [String] = []
    var sportsWatchedGames: [String] = []
    var sportsAutoFollow: Bool = true
    var sportsStartAlerts: Bool = false
    var sportsScoreAlerts: Bool = false
    // MARK: Clipboard
    /// Keep the last few copied texts on the shelf (in memory only, never saved to disk).
    var clipboardHistory: Bool = false

    // MARK: Volume / brightness HUD
    /// "replace": Cove handles the volume/brightness keys and hides the system pop-up (needs Accessibility).
    /// "passive": show Cove's HUD next to the system one. "off": no HUD.
    var hud: String = "replace"
    var hudSeconds: Double = 1.4

    // MARK: Keyboard
    /// ⌃⌥Space opens the island; ⌃⌥Y / N / A / T answer Claude's permission prompts.
    var shortcuts: Bool = true

    // MARK: GitHub Actions
    /// Live activity while your GitHub Actions runs work, and a banner when they pass or fail.
    /// Signs in through the GitHub CLI (`gh auth login`).
    var ciMonitor: Bool = false
    /// "owner/repo" to watch every run on. Empty: your own runs on repos you pushed to recently.
    var ciRepos: [String] = []
    /// Re-run buttons on failed runs and "Run Deploy" on passed ones (repos with a hand-started
    /// deploy or release workflow). Needs the gh token's repo scope (workflow for some repos).
    var ciActions: Bool = true

    // MARK: Claude in the cloud
    /// Show pull requests from Claude cloud sessions (claude.ai/code, Claude projects) as they open,
    /// run CI and merge. Uses the GitHub CLI's sign-in (`gh auth login`).
    var cloudSessions: Bool = true
    /// Repos to watch ("owner/name"). Empty: the ones you pushed to in the last two days.
    var cloudRepos: [String] = []

    // MARK: Your phone
    /// Push agent pings to your phone through ntfy (free app for iOS and Android, or ntfy.sh in a browser).
    var phoneRelay: Bool = false
    /// The private ntfy topic. Made up randomly the first time you turn this on; treat it like a password.
    var phoneTopic: String = ""
    /// ntfy server. The public ntfy.sh works with no account; use your own for privacy.
    var phoneServer: String = "https://ntfy.sh"
    /// Access token for a server that needs sign-in (empty for ntfy.sh).
    var phoneToken: String = ""
    /// Only buzz the phone when the screen is locked or you've been idle (approvalIdleMinutes).
    var phoneOnlyWhenAway: Bool = true
    /// Allow / Deny buttons on Claude's permission prompts. While you're away, prompts wait for the phone
    /// instead of the terminal.
    var phoneApprovals: Bool = false

    // MARK: Bluetooth
    /// AirPods and other Bluetooth accessories: battery when they connect, and when they run low.
    var bluetoothBattery: Bool = false

    // MARK: Privacy
    /// A green dot beside the notch while any camera is on, orange while a microphone is, like the iPhone.
    var privacyIndicator: Bool = true

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
        // Older white-theme values fall back to the consistent black appearance.
        islandTheme = value(.islandTheme, d.islandTheme)
        buttonLook = value(.buttonLook, d.buttonLook)
        islandDisplay = value(.islandDisplay, d.islandDisplay)
        mirrorNotifications = value(.mirrorNotifications, d.mirrorNotifications)
        ignoreApps = value(.ignoreApps, d.ignoreApps)
        highlightKeywords = value(.highlightKeywords, d.highlightKeywords)
        showToolActivity = value(.showToolActivity, d.showToolActivity)
        bannerReplies = value(.bannerReplies, d.bannerReplies)
        mediaApps = value(.mediaApps, d.mediaApps)
        batteryAlerts = value(.batteryAlerts, d.batteryAlerts)
        chargingAnimation = value(.chargingAnimation, d.chargingAnimation)
        focusMinutes = value(.focusMinutes, d.focusMinutes)
        approvals = value(.approvals, d.approvals)
        approvalTimeout = value(.approvalTimeout, d.approvalTimeout)
        approvalIdleMinutes = value(.approvalIdleMinutes, d.approvalIdleMinutes)
        calendar = value(.calendar, d.calendar)
        countdownMinutes = value(.countdownMinutes, d.countdownMinutes)
        meetingAlertMinutes = value(.meetingAlertMinutes, d.meetingAlertMinutes)
        assignmentCalendars = value(.assignmentCalendars, d.assignmentCalendars)
        calendarFeeds = value(.calendarFeeds, d.calendarFeeds)
        reminderLists = value(.reminderLists, d.reminderLists)
        dueLookaheadDays = value(.dueLookaheadDays, d.dueLookaheadDays)
        dueAlertHours = value(.dueAlertHours, d.dueAlertHours)
        ignoreCalendars = value(.ignoreCalendars, d.ignoreCalendars)
        screenshotsToShelf = value(.screenshotsToShelf, d.screenshotsToShelf)
        screenshotBanners = value(.screenshotBanners, d.screenshotBanners)
        screenshotsMoveOffDesktop = value(.screenshotsMoveOffDesktop, d.screenshotsMoveOffDesktop)
        airDropDropZone = value(.airDropDropZone, d.airDropDropZone)
        homeWidget = value(.homeWidget, d.homeWidget)
        desktopAIActivity = value(.desktopAIActivity, d.desktopAIActivity)
        aiWorkInNotch = value(.aiWorkInNotch, d.aiWorkInNotch)
        sportsEnabled = value(.sportsEnabled, d.sportsEnabled)
        sportsLeague = value(.sportsLeague, d.sportsLeague)
        sportsGameID = value(.sportsGameID, d.sportsGameID)
        sportsRankedOnly = value(.sportsRankedOnly, d.sportsRankedOnly)
        sportsFavoriteTeams = Array(Set(value(.sportsFavoriteTeams, d.sportsFavoriteTeams))).sorted()
        sportsWatchedGames = Array(Set(value(.sportsWatchedGames, d.sportsWatchedGames))).sorted()
        sportsAutoFollow = value(.sportsAutoFollow, d.sportsAutoFollow)
        sportsStartAlerts = value(.sportsStartAlerts, d.sportsStartAlerts)
        sportsScoreAlerts = value(.sportsScoreAlerts, d.sportsScoreAlerts)
        clipboardHistory = value(.clipboardHistory, d.clipboardHistory)
        eventStartAlert = value(.eventStartAlert, d.eventStartAlert)
        buddy = value(.buddy, d.buddy)
        buddyAlwaysVisible = value(.buddyAlwaysVisible, d.buddyAlwaysVisible)
        hud = value(.hud, d.hud)
        hudSeconds = value(.hudSeconds, d.hudSeconds)
        shortcuts = value(.shortcuts, d.shortcuts)
        ciMonitor = value(.ciMonitor, d.ciMonitor)
        ciRepos = value(.ciRepos, d.ciRepos)
        ciActions = value(.ciActions, d.ciActions)
        cloudSessions = value(.cloudSessions, d.cloudSessions)
        cloudRepos = value(.cloudRepos, d.cloudRepos)
        bluetoothBattery = value(.bluetoothBattery, d.bluetoothBattery)
        phoneRelay = value(.phoneRelay, d.phoneRelay)
        phoneTopic = value(.phoneTopic, d.phoneTopic)
        phoneServer = value(.phoneServer, d.phoneServer)
        phoneToken = value(.phoneToken, d.phoneToken)
        phoneOnlyWhenAway = value(.phoneOnlyWhenAway, d.phoneOnlyWhenAway)
        phoneApprovals = value(.phoneApprovals, d.phoneApprovals)
        privacyIndicator = value(.privacyIndicator, d.privacyIndicator)
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
