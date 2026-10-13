import Combine
import Foundation

enum HomeWidget: String, Codable, CaseIterable {
    case auto, calendar, music, focus, sports, ai
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .calendar: return "Calendar"
        case .music: return "Music"
        case .focus: return "Focus"
        case .sports: return "Sports · play-by-play"
        case .ai: return "AI work"
        }
    }
}

enum SportsLeague: String, Codable, CaseIterable {
    case nba, nfl, collegeFootball
    var title: String {
        switch self {
        case .nba: return "NBA"
        case .nfl: return "NFL"
        case .collegeFootball: return "College football"
        }
    }
    var path: String {
        switch self {
        case .nba: return "basketball/nba"
        case .nfl: return "football/nfl"
        case .collegeFootball: return "football/college-football"
        }
    }
    var scoreboardURL: URL {
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/scoreboard")!
        // NFL uses the current week; NBA uses today's games. Include all FBS games for college football.
        if self == .collegeFootball {
            components.queryItems = [URLQueryItem(name: "groups", value: "80"), URLQueryItem(name: "limit", value: "200")]
        }
        return components.url!
    }
    func summaryURL(_ id: String) -> URL {
        var components = URLComponents(string: "https://site.api.espn.com/apis/site/v2/sports/\(path)/summary")!
        components.queryItems = [URLQueryItem(name: "event", value: id)]
        return components.url!
    }
}

struct SportsTeam: Equatable {
    var name: String
    var abbreviation: String
    var score: String
    var rank: Int?
    var id: String? = nil
    var primaryHex: UInt32? = nil
    var alternateHex: UInt32? = nil
    var label: String { rank.map { "#\($0) \(abbreviation)" } ?? abbreviation }

    /// Use the supplied brand hue, lifting very dark colors so labels remain legible on black.
    var accentHex: UInt32 {
        let primary = primaryHex ?? 0xA1A1AA
        if Self.contrastOnBlack(primary) >= 4.5 { return primary }
        if let alternateHex, Self.contrastOnBlack(alternateHex) >= 4.5 { return alternateHex }
        for amount in stride(from: 0.1, through: 0.9, by: 0.1) {
            let lifted = Self.lift(primary, by: amount)
            if Self.contrastOnBlack(lifted) >= 4.5 { return lifted }
        }
        return 0xFFFFFF
    }

    static func colorHex(_ value: Any?) -> UInt32? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hex.count == 6, hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        return UInt32(hex, radix: 16)
    }

    static func contrastOnBlack(_ hex: UInt32) -> Double {
        let channels = [Double((hex >> 16) & 255), Double((hex >> 8) & 255), Double(hex & 255)].map { value -> Double in
            let s = value / 255
            return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
        }
        return (channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722 + 0.05) / 0.05
    }
    private static func lift(_ hex: UInt32, by amount: Double) -> UInt32 {
        let channels = [16, 8, 0].map { shift in
            UInt32((Double((hex >> shift) & 255) * (1 - amount) + 255 * amount).rounded())
        }
        return (channels[0] << 16) | (channels[1] << 8) | channels[2]
    }
}

struct SportsGame: Identifiable, Equatable {
    var id: String
    var league: SportsLeague
    var start: Date?
    var away: SportsTeam
    var home: SportsTeam
    var state: String
    var status: String
    var isLive: Bool { state == "in" }
    var isFinal: Bool { state == "post" }
    var isRanked: Bool { away.rank != nil || home.rank != nil }
    var matchup: String { "\(away.label) @ \(home.label)" }
    var scoreLine: String { "\(away.abbreviation) \(away.score) · \(home.abbreviation) \(home.score)" }
}

struct SportsPlay: Identifiable, Equatable {
    var id: String
    var sequence: Int
    var text: String
    var period: Int
    var clock: String
    var scoring: Bool
    var score: String?
    var teamID: String? = nil
    var timeLabel: String {
        [period > 4 ? "\(period - 4)OT" : period > 0 ? "Q\(period)" : "", clock].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// ESPN's public feeds are not a documented API contract. Keep decoding tolerant of optional fields,
/// but reject an unexpected root so a provider change never masquerades as "no games".
enum SportsParser {
    enum ParseError: Error { case invalidResponse }
    static func scoreboard(_ data: Data, league: SportsLeague) throws -> [SportsGame] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { throw ParseError.invalidResponse }
        return events.compactMap { event in
            guard let id = event["id"] as? String,
                  let competition = (event["competitions"] as? [[String: Any]])?.first else { return nil }
            return game(competition, id: id, league: league, date: event["date"] as? String)
        }.sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            if $0.isFinal != $1.isFinal { return !$0.isFinal }
            return ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture)
        }
    }

    static func summary(_ data: Data, league: SportsLeague) throws -> (SportsGame?, [SportsPlay]) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any],
              let id = header["id"] as? String,
              let competition = (header["competitions"] as? [[String: Any]])?.first else { throw ParseError.invalidResponse }
        let updated = game(competition, id: id, league: league, date: competition["date"] as? String)
        var raw = root["plays"] as? [[String: Any]] ?? []
        if let drives = root["drives"] as? [String: Any] {
            for drive in drives["previous"] as? [[String: Any]] ?? [] {
                raw += drive["plays"] as? [[String: Any]] ?? []
            }
            if let current = drives["current"] as? [String: Any] {
                raw += current["plays"] as? [[String: Any]] ?? []
            }
        }
        var seen = Set<String>()
        let plays = raw.enumerated().compactMap { index, item -> SportsPlay? in
            guard let text = item["text"] as? String, !text.isEmpty else { return nil }
            let id = string(item["id"]) ?? "\(index)-\(text)"
            guard seen.insert(id).inserted else { return nil }
            let period = (item["period"] as? [String: Any])?["number"] as? Int ?? 0
            let clock = (item["clock"] as? [String: Any])?["displayValue"] as? String ?? ""
            let score: String?
            if let away = string(item["awayScore"]), let home = string(item["homeScore"]) { score = "\(away)–\(home)" }
            else { score = nil }
            return SportsPlay(id: id, sequence: Int(string(item["sequenceNumber"]) ?? "") ?? index,
                              text: text, period: period, clock: clock, scoring: item["scoringPlay"] as? Bool ?? false, score: score,
                              teamID: (item["team"] as? [String: Any])?["id"] as? String)
        }.sorted { $0.sequence > $1.sequence }
        // No fallback to scoringPlays: a scoring recap must never be presented as full play-by-play.
        return (updated, Array(plays.prefix(100)))
    }

    private static func game(_ competition: [String: Any], id: String, league: SportsLeague, date: String?) -> SportsGame? {
        guard let competitors = competition["competitors"] as? [[String: Any]],
              let home = competitors.first(where: { $0["homeAway"] as? String == "home" }).flatMap(team),
              let away = competitors.first(where: { $0["homeAway"] as? String == "away" }).flatMap(team) else { return nil }
        let type = (competition["status"] as? [String: Any])?["type"] as? [String: Any] ?? [:]
        return SportsGame(id: id, league: league, start: date.flatMap(parseDate),
                          away: away, home: home, state: type["state"] as? String ?? "pre",
                          status: type["shortDetail"] as? String ?? type["detail"] as? String ?? "Scheduled")
    }
    private static func team(_ competitor: [String: Any]) -> SportsTeam? {
        guard let team = competitor["team"] as? [String: Any],
              let name = team["displayName"] as? String else { return nil }
        let rank = (competitor["curatedRank"] as? [String: Any])?["current"] as? Int
        return SportsTeam(name: name, abbreviation: team["abbreviation"] as? String ?? name,
                          score: string(competitor["score"]) ?? "–", rank: rank.flatMap { (1...25).contains($0) ? $0 : nil },
                          id: team["id"] as? String, primaryHex: SportsTeam.colorHex(team["color"]),
                          alternateHex: SportsTeam.colorHex(team["alternateColor"]))
    }
    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func parseDate(_ text: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mmX"
        return formatter.date(from: text)
    }
}

@MainActor
final class SportsMonitor: ObservableObject {
    @Published private(set) var games: [SportsGame] = []
    @Published private(set) var selectedGame: SportsGame?
    @Published private(set) var plays: [SportsPlay] = []
    @Published private(set) var loading = false
    @Published private(set) var scoreboardError: String?
    @Published private(set) var detailError: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var league: SportsLeague = .nfl
    @Published private(set) var enabled = false
    private var selectedID: String?
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var lastAttempt = Date.distantPast
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func start(config: CoveConfig) {
        update(config: config)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let interval: TimeInterval = self.selectedGame?.isLive == true ? 15 : 60
                if Date().timeIntervalSince(self.lastAttempt) >= interval - 0.5 { self.refresh() }
            }
        }
    }

    func update(config: CoveConfig) {
        let changedLeague = league != config.sportsLeague
        let changed = changedLeague || selectedID != config.sportsGameID || enabled != config.sportsEnabled
        guard changed else { return }
        task?.cancel()
        task = nil
        generation = UUID()
        league = config.sportsLeague
        enabled = config.sportsEnabled
        selectedID = config.sportsGameID
        if changedLeague || !enabled { games = [] }
        selectedGame = games.first { $0.id == selectedID }
        plays = []
        updatedAt = nil
        scoreboardError = nil
        detailError = nil
        loading = false
        if enabled { refresh() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        task?.cancel()
        task = nil
        generation = UUID()
        loading = false
    }

    func refresh() {
        guard enabled, task == nil else { return }
        lastAttempt = Date()
        let token = generation
        let league = league
        let id = selectedID
        loading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token { self.loading = false; self.task = nil }
            }
            do {
                let data = try await self.fetch(league.scoreboardURL)
                let games = try SportsParser.scoreboard(data, league: league)
                guard !Task.isCancelled, self.generation == token else { return }
                self.games = games
                self.scoreboardError = nil
                if let game = games.first(where: { $0.id == id }) { self.selectedGame = game }
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.scoreboardError = "Couldn't refresh games. Check your connection and try again."
            }
            guard let id, !Task.isCancelled, self.generation == token else { return }
            do {
                let data = try await self.fetch(league.summaryURL(id))
                let (game, plays) = try SportsParser.summary(data, league: league)
                guard !Task.isCancelled, self.generation == token else { return }
                guard var game, game.id == id else { throw SportsParser.ParseError.invalidResponse }
                game.away.rank = game.away.rank ?? self.selectedGame?.away.rank
                game.home.rank = game.home.rank ?? self.selectedGame?.home.rank
                game.away.primaryHex = game.away.primaryHex ?? self.selectedGame?.away.primaryHex
                game.away.alternateHex = game.away.alternateHex ?? self.selectedGame?.away.alternateHex
                game.home.primaryHex = game.home.primaryHex ?? self.selectedGame?.home.primaryHex
                game.home.alternateHex = game.home.alternateHex ?? self.selectedGame?.home.alternateHex
                self.selectedGame = game
                self.plays = plays
                self.detailError = nil
                self.updatedAt = Date()
            } catch {
                guard !Task.isCancelled, self.generation == token else { return }
                self.detailError = "Updates paused. Showing the last available data. Try refreshing."
            }
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }
}
