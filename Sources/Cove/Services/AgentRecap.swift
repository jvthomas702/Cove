import Foundation

/// One finished Claude Code or Codex run, as listed under "Today" in the AI tab.
struct RecapRun: Codable, Identifiable, Equatable {
    /// The activity id plus when the run started, so a turn that is re-reported replaces itself.
    var id: String
    var activityID: String
    /// `AgentKind` raw value ("claude", "codex").
    var agent: String
    var title: String
    var startedAt: Date
    var finishedAt: Date
    /// How long it ran; nil when Cove only saw it finish.
    var duration: TimeInterval?
    /// Distinct files touched by Edit / Write / MultiEdit; nil when the agent doesn't report tool use.
    var filesChanged: Int?
    var failed: Bool
    /// Where clicking jumps back to (the terminal or app that ran it).
    var ownerApp: String?
    var openURL: URL?

    var kind: AgentKind { AgentKind(rawValue: agent) ?? .custom }
}

/// Today's finished agent runs, newest first. Only one calendar day is ever kept.
struct AgentRecap: Codable, Equatable {
    /// Start of the day these runs belong to.
    var day: Date
    var runs: [RecapRun] = []

    static let limit = 100

    init(day: Date, calendar: Calendar = .current) {
        self.day = calendar.startOfDay(for: day)
    }

    var totalDuration: TimeInterval { runs.compactMap(\.duration).reduce(0, +) }

    /// Starts a fresh day once `now` is past the recap's day. Returns whether anything changed.
    @discardableResult
    mutating func roll(to now: Date, calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard today != day else { return false }
        self = AgentRecap(day: today, calendar: calendar)
        return true
    }

    /// Adds a run (or replaces one with the same id), rolling over first if it finished on a new day.
    mutating func record(_ run: RecapRun, calendar: Calendar = .current) {
        if calendar.startOfDay(for: run.finishedAt) > day { roll(to: run.finishedAt, calendar: calendar) }
        guard calendar.isDate(run.finishedAt, inSameDayAs: day) else { return }
        runs.removeAll { $0.id == run.id }
        let index = runs.firstIndex { $0.finishedAt < run.finishedAt } ?? runs.endIndex
        runs.insert(run, at: index)
        if runs.count > Self.limit { runs.removeLast(runs.count - Self.limit) }
    }
}

/// Files an agent run has edited so far, from Claude Code's PreToolUse / PostToolUse hooks.
struct FileChangeTracker {
    static let editingTools: Set<String> = ["Edit", "Write", "MultiEdit"]
    private var files: [String: Set<String>] = [:]

    /// Notes a tool use. Only file-editing tools count; the same file edited twice counts once.
    mutating func note(activityID: String, tool: String, input: [String: Any]) {
        guard Self.editingTools.contains(tool) else { return }
        let path = (input["file_path"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "\(tool)#\(files[activityID]?.count ?? 0)"
        files[activityID, default: []].insert(path)
    }

    mutating func reset(_ activityID: String) { files.removeValue(forKey: activityID) }

    /// The count for the run that just finished; nil if no edits were seen.
    mutating func take(_ activityID: String) -> Int? { files.removeValue(forKey: activityID)?.count }
}

/// Keeps today's recap in a small JSON file in Application Support, next to the shelf's copies.
final class AgentRecapStore {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, isDirectory: true)
            .appendingPathComponent("AgentRecap.json")
    }

    /// Today's runs; anything saved on an earlier day is dropped.
    func load(now: Date = Date(), calendar: Calendar = .current) -> AgentRecap {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: url), var recap = try? decoder.decode(AgentRecap.self, from: data) else {
            return AgentRecap(day: now, calendar: calendar)
        }
        recap.roll(to: now, calendar: calendar)
        return recap
    }

    func save(_ recap: AgentRecap) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(recap).write(to: url, options: .atomic)
        } catch {
            NSLog("Cove: could not save the agent recap: \(error)")
        }
    }
}
