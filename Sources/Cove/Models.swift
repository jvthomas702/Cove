import AppKit
import SwiftUI

// MARK: - Palette

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum Palette {
    static let claude = Color(hex: 0xD97757)
    static let codex = Color(hex: 0x7EE0B5)
    static let command = Color(hex: 0x8AB4F8)
    static let green = Color(hex: 0x30D158)
    static let amber = Color(hex: 0xFFB340)
    static let red = Color(hex: 0xFF453A)
    static let blue = Color(hex: 0x0A84FF)
    static let spotify = Color(hex: 0x1DB954)
    static let music = Color(hex: 0xFA2D48)
}

// MARK: - Live activities (agents, long commands)

enum AgentKind: String {
    case claude, codex, command, custom

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .command: return "Command"
        case .custom: return "Task"
        }
    }

    var symbol: String {
        switch self {
        case .claude: return "sparkle"
        case .codex: return "chevron.left.forwardslash.chevron.right"
        case .command: return "terminal"
        case .custom: return "bell.fill"
        }
    }

    var tint: Color {
        switch self {
        case .claude: return Palette.claude
        case .codex: return Palette.codex
        case .command: return Palette.command
        case .custom: return .white
        }
    }

    var doneTitle: String {
        switch self {
        case .claude, .codex: return "\(displayName) is done"
        case .command: return "Command finished"
        case .custom: return "Done"
        }
    }
}

enum ActivityState: Equatable {
    case running, attention, done, failed
}

struct Activity: Identifiable, Equatable {
    let id: String
    var agent: AgentKind
    var title: String
    var detail: String
    var state: ActivityState
    var progress: Double? = nil
    var startedAt: Date
    var updatedAt: Date
    var finishedAt: Date? = nil
    /// False for a finished activity you haven't looked at yet (drives the green "new" dot).
    var seen: Bool = true
    /// The app that was frontmost when the work started (usually your terminal); clicking jumps back to it.
    var ownerApp: String? = nil

    var isLive: Bool { state == .running || state == .attention }
}

// MARK: - Banners (transient notifications)

enum BannerStyle: Equatable {
    case info, success, attention, failure

    var tint: Color {
        switch self {
        case .info: return Palette.blue
        case .success: return Palette.green
        case .attention: return Palette.amber
        case .failure: return Palette.red
        }
    }
}

enum BannerIcon: Equatable {
    case symbol(String, Color)
    case app(String)
    /// A file thumbnail (screenshots).
    case file(URL)
}

struct Banner: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var body: String
    var style: BannerStyle
    var icon: BannerIcon
    /// Sticky banners stay until clicked or until you open the island.
    var sticky: Bool = false
    var openApp: String? = nil
    var openURL: URL? = nil
    var date = Date()
    var activityID: String? = nil
    /// Overrides the default on-screen time for non-sticky banners.
    var duration: TimeInterval? = nil
    /// Clicking opens the shelf tab.
    var showsShelf: Bool = false
}

// MARK: - Event API payload

/// Body of `POST /event`. Only `title` is required.
struct CoveEvent: Decodable {
    var id: String?
    var title: String
    var body: String?
    /// info | running | done | error | attention | clear
    var kind: String?
    /// claude | codex | command | custom
    var source: String?
    /// 0…1 for a progress ring on a running activity.
    var progress: Double?
    var sticky: Bool?
}

// MARK: - Media & power

struct NowPlaying: Equatable {
    var bundleID: String
    var title: String
    var artist: String
    var isPlaying: Bool
    var artworkURL: URL?
    /// Seconds into the track and track length, when the player reports them.
    var position: Double? = nil
    var duration: Double? = nil
    /// When `position` was read, so the progress bar can run smoothly between polls.
    var readAt = Date()

    /// Identifies the track (not the moment), for artwork caching.
    var trackKey: String { "\(bundleID)|\(title)|\(artist)" }

    /// The player's own color, used until the artwork's color is known.
    var appTint: Color { bundleID == "com.spotify.client" ? Palette.spotify : Palette.music }

    /// Estimated position right now.
    func elapsed(at date: Date = Date()) -> Double? {
        guard let position else { return nil }
        let live = isPlaying ? position + date.timeIntervalSince(readAt) : position
        if let duration { return min(max(live, 0), duration) }
        return max(live, 0)
    }

    /// Equality ignores the read time and small position drift, so polling doesn't redraw everything.
    static func == (a: NowPlaying, b: NowPlaying) -> Bool {
        a.bundleID == b.bundleID && a.title == b.title && a.artist == b.artist && a.isPlaying == b.isPlaying
            && a.artworkURL == b.artworkURL && a.duration == b.duration
            && abs((a.elapsed() ?? 0) - (b.elapsed() ?? 0)) < 2.5
    }
}

struct BatteryState: Equatable {
    var percent: Int
    var pluggedIn: Bool
    var charging: Bool

    var symbol: String {
        if pluggedIn { return "battery.100.bolt" }
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }
}

// MARK: - Calendar

struct CalEvent: Identifiable, Equatable {
    let id: String
    var title: String
    var start: Date
    var end: Date
    var location: String?
    var calendar: String
    var color: Color
    /// Zoom / Meet / Teams / Webex link found in the event, if any.
    var joinURL: URL?
}

struct DueItem: Identifiable, Equatable {
    let id: String
    var title: String
    var due: Date
    /// Reminders list or calendar it came from.
    var source: String
    var color: Color
}

struct Schedule: Equatable {
    var events: [CalEvent] = []   // timed events, sorted by start
    var due: [DueItem] = []       // assignments & reminders, sorted by due date

    /// The next event that hasn't started, or one that started in the last 5 minutes.
    func nextEvent(at now: Date = Date()) -> CalEvent? {
        events.first { $0.start > now.addingTimeInterval(-300) && $0.end > now }
    }
}

// MARK: - Volume / brightness HUD

struct HUDState: Equatable {
    enum Kind: Equatable { case volume, brightness }
    var kind: Kind
    var level: Double
    var muted: Bool = false
    /// Changes on every update so a repeated level still restarts the hide timer.
    var stamp = UUID()

    var symbol: String {
        switch kind {
        case .brightness:
            return level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if muted || level <= 0.001 { return "speaker.slash.fill" }
            if level < 0.34 { return "speaker.wave.1.fill" }
            if level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }
}

// MARK: - Claude Code permission requests

enum ApprovalDecision {
    case allow, allowAlways, deny, ask
}

struct ApprovalPreview: Equatable {
    enum Style: Equatable { case plain, code, added, removed, meta }
    struct Line: Equatable, Identifiable {
        let id: Int
        let text: String
        let style: Style
    }
    var lines: [Line]
}

struct ApprovalRequest: Identifiable {
    let id = UUID()
    let sessionID: String
    let project: String
    let tool: String
    /// "run a command", "edit eval.py", …
    let action: String
    let preview: ApprovalPreview
    /// Claude's suggested "don't ask again" rules; present only when "Always allow" makes sense.
    let canAlwaysAllow: Bool
    let createdAt = Date()
    let expiresAt: Date
}

// MARK: - Helpers

@MainActor
enum AppIcons {
    private static var icons: [String: NSImage] = [:]
    private static var names: [String: String] = [:]

    static func url(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        guard let url = url(for: bundleID) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        icons[bundleID] = image
        return image
    }

    static func name(for bundleID: String) -> String {
        if let cached = names[bundleID] { return cached }
        let name = url(for: bundleID)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? bundleID
        names[bundleID] = name
        return name
    }
}

extension String {
    /// Collapses whitespace/newlines and truncates with an ellipsis.
    func oneLine(max: Int) -> String {
        let collapsed = self
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if collapsed.count <= max { return collapsed }
        return String(collapsed.prefix(max - 1)) + "…"
    }
}

func formatDuration(_ interval: TimeInterval) -> String {
    let s = Int(interval.rounded())
    if s >= 3600 { return "\(s / 3600)h \((s % 3600) / 60)m" }
    if s >= 60 { return "\(s / 60)m \(s % 60)s" }
    return "\(s)s"
}
