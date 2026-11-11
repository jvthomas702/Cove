import Foundation

enum AIUsageSource: String, Codable, CaseIterable {
    case cloud, desktop, terminal

    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .cloud: return "cloud"
        case .desktop: return "desktopcomputer"
        case .terminal: return "terminal"
        }
    }
}

/// Only session identifiers and reported counts are stored; no prompts or replies.
struct AIUsageSession: Codable, Equatable {
    var source: AIUsageSource
    var tokens: TokenUsage?
}

struct AIUsageSummary: Equatable {
    var sessions: Int
    var reportingSessions: Int
    var tokens: TokenUsage?

    var tokenLabel: String {
        guard let tokens else { return sessions == 0 ? "No usage observed" : "Tokens unavailable" }
        return tokens.short + (reportingSessions < sessions ? " reported" : "")
    }
}

/// Session totals, rather than per-turn totals: a repeated hook replaces the same session's count.
/// The day describes when Cove observed the session; tokens can include earlier turns in that session.
struct AIUsage: Codable, Equatable {
    var day: Date
    var sessions: [String: AIUsageSession] = [:]

    init(now: Date = Date(), calendar: Calendar = .current) { day = calendar.startOfDay(for: now) }

    @discardableResult
    mutating func roll(to now: Date, calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        guard day != today else { return false }
        self = AIUsage(now: now, calendar: calendar)
        return true
    }

    @discardableResult
    mutating func record(_ activity: Activity, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard activity.agent.isAI else { return false }
        let rolled = roll(to: now, calendar: calendar)
        let entry = AIUsageSession(source: activity.usageSource, tokens: activity.tokens ?? sessions[activity.id]?.tokens)
        guard sessions[activity.id] != entry else { return rolled }
        sessions[activity.id] = entry
        return true
    }

    func summary(for source: AIUsageSource) -> AIUsageSummary {
        let entries = sessions.values.filter { $0.source == source }
        let known = entries.compactMap(\.tokens)
        let total = known.reduce(TokenUsage(input: 0, output: 0)) { TokenUsage(input: $0.input + $1.input, output: $0.output + $1.output) }
        return AIUsageSummary(sessions: entries.count, reportingSessions: known.count, tokens: known.isEmpty ? nil : total)
    }
}

final class AIUsageStore {
    let url: URL

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, isDirectory: true)
            .appendingPathComponent("AIUsage.json")
    }

    func load(now: Date = Date(), calendar: Calendar = .current) -> AIUsage {
        guard let data = try? Data(contentsOf: url), var usage = try? JSONDecoder().decode(AIUsage.self, from: data) else {
            return AIUsage(now: now, calendar: calendar)
        }
        usage.roll(to: now, calendar: calendar)
        return usage
    }

    func save(_ usage: AIUsage) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(usage).write(to: url, options: .atomic)
        } catch { NSLog("Cove: could not save AI usage: \(error)") }
    }
}
