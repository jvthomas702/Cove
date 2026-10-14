import SwiftUI

struct SportsFavoritesPicker: View {
    @ObservedObject var model: IslandModel
    @State private var league = SportsLeague.nba
    @State private var search = ""
    private var teams: [SportsCatalog.Team] {
        SportsCatalog.teams.filter { $0.league == league && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.abbreviation.localizedCaseInsensitiveContains(search)) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Favorite teams league", selection: $league) {
                ForEach(SportsLeague.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            TextField("Find a team", text: $search).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("sports.favoriteSearch")
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 6) {
                    ForEach(teams) { team in
                        Button { model.toggleFavorite(team.id, league: team.league) } label: {
                            HStack(spacing: 6) {
                                TeamLogo(team: team.sportsTeam, size: 24)
                                Text(team.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                Image(systemName: model.config.sportsFavoriteTeams.contains(team.key) ? "star.fill" : "star")
                                    .foregroundStyle(model.config.sportsFavoriteTeams.contains(team.key) ? Palette.amber : .secondary)
                            }.font(.caption).padding(6).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("sports.favorite.\(team.key)")
                    }
                }
            }.frame(height: 180)
            if teams.isEmpty { Text("No matching teams").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct FollowedScoresStrip: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        if model.followedSportsGames.count > 1 {
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(model.followedSportsGames, id: \.key) { game in
                        Button { model.chooseSportsGame(game) } label: {
                            HStack(spacing: 4) {
                                TeamLogo(team: game.away, size: 16)
                                Text(game.away.abbreviation)
                                Text(game.away.score).monospacedDigit()
                                Text("–").foregroundStyle(Theme.inkTertiary)
                                Text(game.home.score).monospacedDigit()
                                TeamLogo(team: game.home, size: 16)
                                if game.isLive { Circle().fill(Palette.green).frame(width: 4, height: 4) }
                            }.font(.system(size: 10, weight: .semibold))
                                .padding(6).background(RoundedRectangle(cornerRadius: 8).fill(game.id == model.config.sportsGameID && game.league == model.config.sportsLeague ? Theme.surfaceRaised : Theme.surface))
                        }.buttonStyle(.plain).help("\(game.matchup) · \(game.status)")
                            .accessibilityLabel("\(game.matchup), \(game.scoreLine), \(game.status)")
                            .accessibilityIdentifier("sports.followed.\(game.key)")
                    }
                }
            }.frame(height: 32).accessibilityIdentifier("sports.followedScores")
        }
    }
}
