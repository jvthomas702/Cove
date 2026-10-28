import Foundation

struct SportsCatalog {
    struct Team: Decodable, Identifiable {
        var id: String
        var league: SportsLeague
        var name: String
        var abbreviation: String
        var color: String?
        var alternateColor: String?
        var logo: String?
        private enum CodingKeys: String, CodingKey { case name, abbreviation, color, alternateColor, logo }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = ""; league = .nba
            name = try c.decode(String.self, forKey: .name)
            abbreviation = try c.decode(String.self, forKey: .abbreviation)
            color = try c.decodeIfPresent(String.self, forKey: .color)
            alternateColor = try c.decodeIfPresent(String.self, forKey: .alternateColor)
            logo = try c.decodeIfPresent(String.self, forKey: .logo)
        }
        var key: String { "\(league.rawValue):\(id)" }
        var sportsTeam: SportsTeam {
            SportsTeam(name: name, abbreviation: abbreviation, score: "–", rank: nil, id: id,
                       primaryHex: SportsTeam.colorHex(color), alternateHex: SportsTeam.colorHex(alternateColor),
                       logoURL: SportsTeam.logoURL(logo), league: league)
        }
    }
    static let teams: [Team] = load(bundle: .main)
    static func load(bundle: Bundle) -> [Team] {
        guard let url = bundle.url(forResource: "catalog", withExtension: "json", subdirectory: "TeamLogos"),
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode([String: Team].self, from: data) else { return [] }
        return catalog.compactMap { key, value in
            let parts = key.split(separator: "-", maxSplits: 1)
            guard parts.count == 2, let league = SportsLeague(rawValue: parts[0] == "cfb" ? "collegeFootball" : String(parts[0])) else { return nil }
            var team = value; team.id = String(parts[1]); team.league = league; return team
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    static func team(id: String?, league: SportsLeague) -> Team? { teams.first { $0.id == id && $0.league == league } }
}

extension SportsGame {
    var key: String { "\(league.rawValue):\(id)" }
    func isFavorite(in config: CoveConfig) -> Bool {
        teamIDs.contains { config.sportsFavoriteTeams.contains("\(league.rawValue):\($0)") }
    }
    func isFollowed(in config: CoveConfig) -> Bool { isFavorite(in: config) || config.sportsWatchedGames.contains(key) }
}

enum SportsFollowRules {
    /// Keys of games followed one at a time that have now ended, so they can be dropped.
    static func finishedWatchedGames(_ games: [SportsGame], config: CoveConfig) -> Set<String> {
        Set(games.filter(\.isFinal).map(\.key)).intersection(config.sportsWatchedGames)
    }

    /// The pinned game has ended: unpin it, so the notch stops showing a final score. A game you pinned
    /// after it ended stays (see `sportsPinnedFinalGame`).
    static func shouldUnpin(_ pinned: SportsGame?, config: CoveConfig) -> Bool {
        guard let pinned, pinned.id == config.sportsGameID, pinned.league == config.sportsLeague, pinned.isFinal else { return false }
        return !config.sportsPinnedFinalGame
    }

    static func automaticGame(_ games: [SportsGame], current: SportsGame?, config: CoveConfig) -> SportsGame? {
        guard config.sportsAutoFollow, !config.sportsFavoriteTeams.isEmpty else { return nil }
        // Respect a manually chosen game while it is active, and keep stable selection between polls.
        if let current, !current.isFinal { return nil }
        return games.filter { $0.isFavorite(in: config) && !$0.isFinal }.sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            return ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture)
        }.first
    }
}

struct SportsAlertTracker {
    private var previous: [String: SportsGame] = [:]
    struct Alert { var title: String; var body: String }
    mutating func consume(_ games: [SportsGame], config: CoveConfig) -> [Alert] {
        var alerts: [Alert] = []
        for game in games {
            defer { previous[game.key] = game }
            guard let old = previous[game.key], game.isFollowed(in: config) || (game.id == config.sportsGameID && game.league == config.sportsLeague) else { continue }
            if config.sportsStartAlerts && old.state == "pre" && game.isLive {
                alerts.append(Alert(title: "\(game.matchup) is live", body: game.status))
            }
            if config.sportsScoreAlerts, (game.isLive || game.isFinal),
               let oldAway = Int(old.away.score), let oldHome = Int(old.home.score),
               let away = Int(game.away.score), let home = Int(game.home.score), away + home > oldAway + oldHome {
                alerts.append(Alert(title: game.isFinal ? "Final · \(game.matchup)" : "Score update · \(game.matchup)", body: game.scoreLine))
            }
        }
        return alerts
    }
}
