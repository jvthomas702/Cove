import Foundation

struct SportsDrive: Identifiable, Equatable {
    var id: String
    var teamID: String?
    var result: String
    var summary: String
    var period: Int
    var clock: String
    var scoring: Bool
    var current: Bool
    var playIDs: [String]
    var sequence: Int
}

struct SportsStat: Identifiable, Equatable {
    var id: String
    var label: String
    var values: [String: String]
}

struct SportsLeader: Identifiable, Equatable {
    var id: String
    var teamID: String
    var name: String
    var category: String
    var value: String
}

struct SportsSituation: Equatable {
    var teamID: String?
    var text: String
}

struct SportsSnapshot {
    var game: SportsGame?
    var plays: [SportsPlay]
    var drives: [SportsDrive]
    var stats: [SportsStat]
    var leaders: [SportsLeader]
    var situation: SportsSituation?
}

enum SportsPlayFilter {
    static func apply(_ plays: [SportsPlay], period: Int?, scoringOnly: Bool) -> [SportsPlay] {
        plays.filter { (period == nil || $0.period == period) && (!scoringOnly || $0.scoring) }
    }
    static func periodName(_ period: Int) -> String { period > 4 ? "OT\(period - 4)" : "Q\(period)" }
}

extension SportsParser {
    static func gameSummary(_ data: Data, league: SportsLeague) throws -> SportsSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = root["header"] as? [String: Any],
              let id = header["id"] as? String,
              let competition = (header["competitions"] as? [[String: Any]])?.first else { throw ParseError.invalidResponse }
        let game = game(competition, id: id, league: league, date: competition["date"] as? String)
        let box = root["boxscore"] as? [String: Any] ?? [:]
        var names: [String: String] = [:]
        for team in box["players"] as? [[String: Any]] ?? [] {
            for group in team["statistics"] as? [[String: Any]] ?? [] {
                for player in group["athletes"] as? [[String: Any]] ?? [] {
                    if let athlete = player["athlete"] as? [String: Any], let id = string(athlete["id"]),
                       let name = athlete["displayName"] as? String { names[id] = name }
                }
            }
        }
        var raw = root["plays"] as? [[String: Any]] ?? []
        var drives: [SportsDrive] = []
        if let feed = root["drives"] as? [String: Any] {
            var groups = (feed["previous"] as? [[String: Any]] ?? []).map { ($0, false) }
            if let current = feed["current"] as? [String: Any] { groups.append((current, true)) }
            for (index, entry) in groups.enumerated() {
                let (drive, current) = entry
                let plays = drive["plays"] as? [[String: Any]] ?? []
                let driveID = string(drive["id"]) ?? "drive-\(index)"
                let teamID = (drive["team"] as? [String: Any]).flatMap { string($0["id"]) }
                let start = drive["start"] as? [String: Any] ?? [:]
                let ids = plays.enumerated().map { playID($0.element, index: $0.offset, prefix: driveID) }
                for (offset, play) in plays.enumerated() {
                    var enriched = play
                    enriched["coveDriveID"] = driveID
                    enriched["coveDriveTeamID"] = teamID
                    enriched["id"] = ids[offset]
                    raw.append(enriched)
                }
                let clock = (start["clock"] as? [String: Any])?["displayValue"] as? String ?? ""
                drives.append(SportsDrive(id: driveID, teamID: teamID,
                    result: drive["displayResult"] as? String ?? drive["result"] as? String ?? (current ? "In progress" : "Drive"),
                    summary: drive["description"] as? String ?? "",
                    period: (start["period"] as? [String: Any])?["number"] as? Int ?? (plays.first?["period"] as? [String: Any])?["number"] as? Int ?? 0,
                    clock: clock, scoring: drive["isScore"] as? Bool ?? false, current: current && game?.isLive == true,
                    playIDs: ids, sequence: plays.compactMap { Int(string($0["sequenceNumber"]) ?? "") }.max() ?? index))
            }
        }
        // Prefer a corrected/current copy of a play when the provider repeats its ID across feeds.
        var unique: [String: (Int, [String: Any])] = [:]
        for (index, play) in raw.enumerated() {
            let id = playID(play, index: index)
            unique[id] = (index, play)
        }
        let ordered = unique.map { (id: $0.key, index: $0.value.0, value: $0.value.1) }.sorted {
            let a = Int(string($0.value["sequenceNumber"]) ?? "") ?? $0.index
            let b = Int(string($1.value["sequenceNumber"]) ?? "") ?? $1.index
            return a == b ? $0.index < $1.index : a < b
        }
        var homeScore: Int?, awayScore: Int?
        var plays: [SportsPlay] = []
        for item in ordered {
            let play = item.value
            guard let text = play["text"] as? String, !text.isEmpty else { continue }
            let period = (play["period"] as? [String: Any])?["number"] as? Int ?? 0
            let start = play["start"] as? [String: Any] ?? [:]
            let end = play["end"] as? [String: Any] ?? [:]
            let away = string(play["awayScore"]), home = string(play["homeScore"])
            let nextHome = home.flatMap(Int.init), nextAway = away.flatMap(Int.init)
            let scoring = play["scoringPlay"] as? Bool ?? false
            var teamID = (play["team"] as? [String: Any]).flatMap { string($0["id"]) }
            if teamID == nil, scoring, let previousHome = homeScore, let previousAway = awayScore,
               let h = nextHome, let a = nextAway {
                if h > previousHome, a == previousAway { teamID = game?.home.id }
                if a > previousAway, h == previousHome { teamID = game?.away.id }
            }
            teamID = teamID ?? string(start["team"].flatMap { ($0 as? [String: Any])?["id"] })
            if teamID == nil {
                teamID = (play["teamParticipants"] as? [[String: Any]])?.first(where: { $0["type"] as? String == "offense" }).flatMap { string($0["id"]) }
            }
            teamID = teamID ?? play["coveDriveTeamID"] as? String
            let participants = (play["participants"] as? [[String: Any]] ?? []).compactMap { participant -> String? in
                guard let athlete = participant["athlete"] as? [String: Any] else { return nil }
                return athlete["displayName"] as? String ?? string(athlete["id"]).flatMap { names[$0] }
            }
            var seenNames = Set<String>()
            let athleteNames = participants.filter { seenNames.insert($0).inserted }
            let action = (play["scoringType"] as? [String: Any])?["displayName"] as? String
                ?? (play["type"] as? [String: Any])?["text"] as? String
            let downDistance = start["shortDownDistanceText"] as? String
            let position = start["possessionText"] as? String
            plays.append(SportsPlay(id: item.id,
                sequence: Int(string(play["sequenceNumber"]) ?? "") ?? item.index,
                text: text, period: period, clock: (play["clock"] as? [String: Any])?["displayValue"] as? String ?? "",
                scoring: scoring, score: away.flatMap { a in home.map { "\(a)–\($0)" } }, teamID: teamID,
                action: action, scoreValue: league == .nba ? (play["scoreValue"] as? Int) : nil,
                downDistance: downDistance, fieldPosition: position,
                yards: (start["down"] as? Int ?? 0) > 0 ? play["statYardage"] as? Int : nil,
                turnover: play["isTurnover"] as? Bool ?? false, penalty: play["isPenalty"] as? Bool ?? false,
                athleteNames: athleteNames, driveID: play["coveDriveID"] as? String,
                wallclock: (play["wallclock"] as? String).flatMap(parseDate),
                endSituation: end["downDistanceText"] as? String,
                endTeamID: (end["team"] as? [String: Any]).flatMap { string($0["id"]) }))
            homeScore = nextHome ?? homeScore; awayScore = nextAway ?? awayScore
        }
        plays.reverse()
        var stats: [SportsStat] = []
        for team in box["teams"] as? [[String: Any]] ?? [] {
            guard let teamID = (team["team"] as? [String: Any]).flatMap({ string($0["id"]) }) else { continue }
            for item in team["statistics"] as? [[String: Any]] ?? [] {
                guard let id = item["name"] as? String, let value = string(item["displayValue"]) else { continue }
                if let index = stats.firstIndex(where: { $0.id == id }) { stats[index].values[teamID] = value }
                else { stats.append(SportsStat(id: id, label: item["label"] as? String ?? id, values: [teamID: value])) }
            }
        }
        var leaders: [SportsLeader] = []
        for team in root["leaders"] as? [[String: Any]] ?? [] {
            guard let teamID = (team["team"] as? [String: Any]).flatMap({ string($0["id"]) }) else { continue }
            for category in team["leaders"] as? [[String: Any]] ?? [] {
                guard let metric = category["name"] as? String,
                      let leader = (category["leaders"] as? [[String: Any]])?.first,
                      let athlete = leader["athlete"] as? [String: Any], let name = athlete["displayName"] as? String,
                      let value = string(leader["displayValue"]) else { continue }
                leaders.append(SportsLeader(id: "\(teamID)-\(metric)", teamID: teamID, name: name,
                    category: category["displayName"] as? String ?? metric, value: value))
            }
        }
        var situation: SportsSituation?
        if game?.isLive == true {
            let supplied = root["situation"] as? [String: Any] ?? competition["situation"] as? [String: Any] ?? [:]
            let text = supplied["downDistanceText"] as? String ?? plays.first?.endSituation
            let teamID = string(supplied["possession"]) ?? plays.first?.endTeamID
            if let text, !text.isEmpty { situation = SportsSituation(teamID: teamID, text: text) }
        }
        let uniqueDrives = drives.reduce(into: [String: SportsDrive]()) { $0[$1.id] = $1 }
        return SportsSnapshot(game: game, plays: plays, drives: uniqueDrives.values.sorted {
            if $0.current != $1.current { return $0.current }
            return $0.sequence > $1.sequence
        },
                              stats: stats, leaders: leaders, situation: situation)
    }

    private static func playID(_ play: [String: Any], index: Int, prefix: String = "play") -> String {
        string(play["id"]) ?? "\(prefix)-\(index)-\(play["text"] as? String ?? "")"
    }
}
