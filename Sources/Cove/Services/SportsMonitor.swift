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
    var logoURL: URL? = nil
    var periodScores: [String] = []
    var league: SportsLeague? = nil
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

    /// Team image addresses supplied by ESPN; ignore non-image or untrusted endpoints.
    static func logoURL(_ value: Any?) -> URL? {
        guard let text = value as? String, let url = URL(string: text),
              url.scheme == "https", let host = url.host?.lowercased(),
              host == "espncdn.com" || host.hasSuffix(".espncdn.com"),
              url.user == nil, url.password == nil,
              ["png", "jpg", "jpeg", "webp"].contains(url.pathExtension.lowercased()) else { return nil }
        return url
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
    var gamecastURL: URL? {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else { return nil }
        let sport = league == .nba ? "nba" : league == .nfl ? "nfl" : "college-football"
        return URL(string: "https://www.espn.com/\(sport)/game/_/gameId/\(id)")
    }
    var teamIDs: [String] { [away.id, home.id].compactMap { $0 } }
    func team(_ id: String?) -> SportsTeam? {
        guard let id else { return nil }
        return away.id == id ? away : home.id == id ? home : nil
    }
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
    var action: String? = nil
    var scoreValue: Int? = nil
    var downDistance: String? = nil
    var fieldPosition: String? = nil
    var yards: Int? = nil
    var turnover = false
    var penalty = false
    var athleteNames: [String] = []
    var driveID: String? = nil
    var wallclock: Date? = nil
    var endSituation: String? = nil
    var endTeamID: String? = nil
    var badge: String? {
        if scoring { return scoreValue.flatMap { $0 > 0 ? "+\($0)" : nil } ?? action ?? "Score" }
        if turnover { return "Turnover" }
        if penalty { return "Penalty" }
        return nil
    }
    var context: String {
        [downDistance, fieldPosition].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
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
        let snapshot = try gameSummary(data, league: league)
        return (snapshot.game, snapshot.plays)
    }

    static func game(_ competition: [String: Any], id: String, league: SportsLeague, date: String?) -> SportsGame? {
        guard let competitors = competition["competitors"] as? [[String: Any]],
              let home = competitors.first(where: { $0["homeAway"] as? String == "home" }).flatMap({ team($0, league: league) }),
              let away = competitors.first(where: { $0["homeAway"] as? String == "away" }).flatMap({ team($0, league: league) }) else { return nil }
        let type = (competition["status"] as? [String: Any])?["type"] as? [String: Any] ?? [:]
        return SportsGame(id: id, league: league, start: date.flatMap(parseDate),
                          away: away, home: home, state: type["state"] as? String ?? "pre",
                          status: type["shortDetail"] as? String ?? type["detail"] as? String ?? "Scheduled")
    }
    private static func team(_ competitor: [String: Any], league: SportsLeague) -> SportsTeam? {
        guard let team = competitor["team"] as? [String: Any],
              let name = team["displayName"] as? String else { return nil }
        let brand = SportsCatalog.team(id: team["id"] as? String, league: league)
        let rank = (competitor["curatedRank"] as? [String: Any])?["current"] as? Int ?? competitor["rank"] as? Int
        return SportsTeam(name: name, abbreviation: team["abbreviation"] as? String ?? name,
                          score: string(competitor["score"]) ?? "–", rank: rank.flatMap { (1...25).contains($0) ? $0 : nil },
                          id: team["id"] as? String, primaryHex: SportsTeam.colorHex(team["color"]) ?? SportsTeam.colorHex(brand?.color),
                          alternateHex: SportsTeam.colorHex(team["alternateColor"]) ?? SportsTeam.colorHex(brand?.alternateColor),
                          logoURL: SportsTeam.logoURL(team["logo"]) ?? (team["logos"] as? [[String: Any]])?.compactMap { SportsTeam.logoURL($0["href"]) }.first ?? SportsTeam.logoURL(brand?.logo),
                          periodScores: (competitor["linescores"] as? [[String: Any]] ?? []).map { string($0["displayValue"]) ?? string($0["value"]) ?? "–" }, league: league)
    }
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func parseDate(_ text: String) -> Date? {
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
    @Published private(set) var allGames: [SportsGame] = []
    @Published private(set) var followedSlateError: String?
    var onAutomaticSelection: ((SportsGame) -> Void)?
    var onAlert: ((SportsAlertTracker.Alert) -> Void)?
    private var preferences = CoveConfig()
    private var slates: [SportsLeague: [SportsGame]] = [:]
    private var alertTracker = SportsAlertTracker()
    @Published private(set) var selectedGame: SportsGame?
    @Published private(set) var plays: [SportsPlay] = []
    @Published private(set) var drives: [SportsDrive] = []
    @Published private(set) var stats: [SportsStat] = []
    @Published private(set) var leaders: [SportsLeader] = []
    @Published private(set) var situation: SportsSituation?
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
    private var lastScoreboardAttempt = Date.distantPast
    private let session: URLSession

    init(session: URLSession = .shared) { self.session = session }

    func start(config: CoveConfig) {
        update(config: config)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let interval: TimeInterval = self.selectedGame?.isLive == true ? 10 : 60
                if Date().timeIntervalSince(self.lastAttempt) >= interval - 0.5 { self.refresh(forceScoreboard: false) }
            }
        }
    }

    func update(config: CoveConfig) {
        let changedPreferences = preferences.sportsFavoriteTeams != config.sportsFavoriteTeams || preferences.sportsWatchedGames != config.sportsWatchedGames || preferences.sportsAutoFollow != config.sportsAutoFollow
        preferences = config
        if changedPreferences { lastScoreboardAttempt = .distantPast }
        let changedLeague = league != config.sportsLeague
        let changed = changedLeague || selectedID != config.sportsGameID || enabled != config.sportsEnabled
        guard changed else { if changedPreferences && enabled { refresh() }; return }
        task?.cancel()
        task = nil
        generation = UUID()
        league = config.sportsLeague
        enabled = config.sportsEnabled
        selectedID = config.sportsGameID
        if changedLeague || !enabled { games = [] }
        if !enabled { slates = [:]; allGames = []; alertTracker = SportsAlertTracker(); followedSlateError = nil }
        selectedGame = games.first { $0.id == selectedID }
        plays = []
        drives = []; stats = []; leaders = []; situation = nil
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

    /// Poll game detail independently of the slate, so a slow scoreboard cannot stall live plays.
    func refresh(forceScoreboard: Bool = true) {
        guard enabled, task == nil else { return }
        lastAttempt = Date()
        let token = generation
        let league = league
        let id = selectedID
        let fetchSlate = forceScoreboard || games.isEmpty || Date().timeIntervalSince(lastScoreboardAttempt) >= 60
        if fetchSlate { lastScoreboardAttempt = Date() }
        loading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token { self.loading = false; self.task = nil }
            }
            let leagues = self.preferences.sportsFavoriteTeams.isEmpty && self.preferences.sportsWatchedGames.isEmpty ? [league] : SportsLeague.allCases
            async let slateResults = self.fetchSlates(fetchSlate ? leagues : [])
            async let detail = self.fetchResult(id.map { league.summaryURL($0) })
            var detailSucceeded = false
            if let result = await detail {
                guard !Task.isCancelled, self.generation == token else { return }
                do {
                    let snapshot = try SportsParser.gameSummary(result.get(), league: league)
                    guard var game = snapshot.game, game.id == id else { throw SportsParser.ParseError.invalidResponse }
                    game.away.rank = game.away.rank ?? self.selectedGame?.away.rank
                    game.home.rank = game.home.rank ?? self.selectedGame?.home.rank
                    game.away.primaryHex = game.away.primaryHex ?? self.selectedGame?.away.primaryHex
                    game.away.alternateHex = game.away.alternateHex ?? self.selectedGame?.away.alternateHex
                    game.home.primaryHex = game.home.primaryHex ?? self.selectedGame?.home.primaryHex
                    game.home.alternateHex = game.home.alternateHex ?? self.selectedGame?.home.alternateHex
                    game.away.logoURL = game.away.logoURL ?? self.selectedGame?.away.logoURL
                    game.home.logoURL = game.home.logoURL ?? self.selectedGame?.home.logoURL
                    self.selectedGame = game
                    self.alertTracker.consume([game], config: self.preferences).forEach { self.onAlert?($0) }
                    if let index = self.games.firstIndex(where: { $0.id == game.id }) { self.games[index] = game }
                    self.plays = snapshot.plays
                    self.drives = snapshot.drives
                    self.stats = snapshot.stats
                    self.leaders = snapshot.leaders
                    self.situation = snapshot.situation
                    self.detailError = nil
                    self.updatedAt = Date()
                    detailSucceeded = true
                } catch {
                    self.detailError = "Updates paused. Showing the last available data. Try refreshing."
                }
            }
            var failedFollowedSlate = false
            for (slateLeague, result) in await slateResults {
                guard !Task.isCancelled, self.generation == token else { return }
                do {
                    var games = try SportsParser.scoreboard(result.get(), league: slateLeague)
                    if slateLeague == league {
                        self.scoreboardError = nil
                        if let game = games.first(where: { $0.id == id }) {
                            if detailSucceeded, var selected = self.selectedGame {
                                selected.away.rank = selected.away.rank ?? game.away.rank
                                selected.home.rank = selected.home.rank ?? game.home.rank
                                selected.away.primaryHex = selected.away.primaryHex ?? game.away.primaryHex
                                selected.home.primaryHex = selected.home.primaryHex ?? game.home.primaryHex
                                selected.away.alternateHex = selected.away.alternateHex ?? game.away.alternateHex
                                selected.home.alternateHex = selected.home.alternateHex ?? game.home.alternateHex
                                selected.away.logoURL = selected.away.logoURL ?? game.away.logoURL
                                selected.home.logoURL = selected.home.logoURL ?? game.home.logoURL
                                self.selectedGame = selected
                                if let index = games.firstIndex(where: { $0.id == selected.id }) { games[index] = selected }
                            } else { self.selectedGame = game }
                        }
                        self.games = games
                    }
                    self.slates[slateLeague] = games
                    self.alertTracker.consume(games, config: self.preferences).forEach { self.onAlert?($0) }
                } catch {
                    failedFollowedSlate = true
                    if slateLeague == league { self.scoreboardError = "Couldn't refresh games. Check your connection and try again." }
                }
            }
            if fetchSlate {
                self.followedSlateError = failedFollowedSlate ? "Some followed scores could not refresh. Showing their last available scores." : nil
            }
            self.allGames = self.slates.values.flatMap { $0 }
            if let selected = self.selectedGame {
                if let index = self.allGames.firstIndex(where: { $0.key == selected.key }) { self.allGames[index] = selected }
                else { self.allGames.append(selected) }
            }
            if self.detailError == nil, let game = SportsFollowRules.automaticGame(self.allGames, current: self.selectedGame, config: self.preferences) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.onAutomaticSelection?(game)
                }
            }
        }
    }

    private func fetchSlates(_ leagues: [SportsLeague]) async -> [(SportsLeague, Result<Data, Error>)] {
        await withTaskGroup(of: (SportsLeague, Result<Data, Error>).self) { group in
            for league in leagues {
                group.addTask { (league, await self.fetchResult(league.scoreboardURL)!) }
            }
            var results: [(SportsLeague, Result<Data, Error>)] = []
            for await result in group { results.append(result) }
            return results
        }
    }

    private func fetchResult(_ url: URL?) async -> Result<Data, Error>? {
        guard let url else { return nil }
        do { return .success(try await fetch(url)) }
        catch { return .failure(error) }
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
