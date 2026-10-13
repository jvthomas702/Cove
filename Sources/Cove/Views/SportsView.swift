import SwiftUI

extension SportsTeam {
    var tint: Color { Color(hex: accentHex) }
    var brandColor: Color { Color(hex: primaryHex ?? 0x71717A) }
}

private struct TeamMatchupBackground: View {
    let game: SportsGame
    var body: some View {
        LinearGradient(colors: [game.away.brandColor.opacity(0.24), Theme.surface, game.home.brandColor.opacity(0.24)],
                       startPoint: .leading, endPoint: .trailing)
    }
}

/// A dedicated, scrollable game picker. Choosing a game pins it to the Home widget and notch.
struct SportsPane: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var sports: SportsMonitor

    init(model: IslandModel) {
        self.model = model
        self.sports = model.sports
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Picker("League", selection: Binding(get: { model.config.sportsLeague }, set: { model.chooseSportsLeague($0) })) {
                    ForEach(SportsLeague.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 305)
                if model.config.sportsLeague == .collegeFootball {
                    Toggle("Top 25", isOn: Binding(get: { model.config.sportsRankedOnly }, set: {
                        var config = model.config
                        config.sportsRankedOnly = $0
                        model.applyConfig?(config)
                    }))
                    .toggleStyle(.checkbox)
                    .font(Theme.Font.caption)
                    .help("Games featuring at least one Top 25 team")
                }
                Spacer(minLength: 0)
                if sports.loading { ProgressView().controlSize(.mini) }
                IconButton(systemImage: "arrow.clockwise", size: 12, hit: 24) { sports.refresh() }
                    .help("Refresh games")
                    .disabled(sports.loading || !sports.enabled)
            }
            if !sports.enabled {
                SportsEmpty(title: "Sports is turned off", detail: "Enable it in Settings → Features.")
                Button("Open settings") { model.openSettings?(.features) }.buttonStyle(.plain)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    gameList.frame(width: 220)
                    SportsDetail(sports: sports)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var gameList: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = sports.scoreboardError {
                Text(error).font(Theme.Font.caption).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
            }
            if model.visibleSportsGames.isEmpty {
                SportsEmpty(title: sports.loading ? "Loading games…" : "No games available",
                            detail: model.config.sportsLeague == .collegeFootball && model.config.sportsRankedOnly
                            ? "No Top 25 matchups in this slate. Turn off Top 25 to see all FBS games."
                            : "Check back for the next slate of games.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(model.visibleSportsGames) { game in
                            Button { model.chooseSportsGame(game) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        HStack(spacing: 5) {
                                            Circle().fill(game.away.tint).frame(width: 5, height: 5)
                                            Text(game.away.label).foregroundStyle(game.away.tint)
                                            Text("@").foregroundStyle(Theme.inkTertiary)
                                            Text(game.home.label).foregroundStyle(game.home.tint)
                                            Circle().fill(game.home.tint).frame(width: 5, height: 5)
                                        }
                                        .font(Theme.Font.headline).lineLimit(1).minimumScaleFactor(0.8)
                                        Spacer(minLength: 0)
                                        if game.id == model.config.sportsGameID {
                                            Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Palette.blue)
                                        }
                                    }
                                    HStack {
                                        Text(game.state == "pre" ? "" : "\(game.away.score)–\(game.home.score)")
                                            .font(Theme.Font.number)
                                        Text(game.status).font(Theme.Font.caption)
                                            .foregroundStyle(game.isLive ? Palette.green : Theme.inkSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(9)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background { TeamMatchupBackground(game: game).clipShape(RoundedRectangle(cornerRadius: 12)) }
                                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(game.id == model.config.sportsGameID ? game.away.tint.opacity(0.65) : Theme.hairline, lineWidth: 1) }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Follow \(game.away.name) at \(game.home.name)")
                        }
                    }
                }
            }
        }
    }
}

private struct SportsDetail: View {
    @ObservedObject var sports: SportsMonitor
    private func scoreTint(_ play: SportsPlay, game: SportsGame) -> Color {
        guard let id = play.teamID else { return Palette.green }
        if id == game.away.id { return game.away.tint }
        if id == game.home.id { return game.home.tint }
        return Palette.green
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let game = sports.selectedGame {
                SportsScoreHeader(game: game)
                if let error = sports.detailError {
                    Text(error).font(Theme.Font.caption).foregroundStyle(Palette.amber)
                }
                HStack {
                    SectionTitle(title: "Play-by-play")
                    Spacer()
                    if let date = sports.updatedAt {
                        Text(date, format: .dateTime.hour().minute().second())
                            .font(.system(size: 9)).foregroundStyle(Theme.inkTertiary)
                            .help("Last successful update · ESPN · live games refresh about every 15 seconds")
                    }
                }
                if sports.plays.isEmpty {
                    SportsEmpty(title: sports.loading ? "Loading plays…" : "No plays yet",
                                detail: game.state == "pre" ? "Play-by-play appears once the game starts." : "ESPN has not provided play-by-play for this game yet.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(sports.plays) { play in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(play.timeLabel).foregroundStyle(Theme.inkTertiary)
                                        Spacer()
                                        if play.scoring, let score = play.score { Text(score).foregroundStyle(scoreTint(play, game: game)) }
                                    }
                                    .font(Theme.Font.number)
                                    Text(play.text).font(Theme.Font.body)
                                        .foregroundStyle(Theme.inkSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                            }
                        }
                    }
                }
            } else {
                SportsEmpty(title: sports.loading && sports.enabled ? "Loading your game…" : "Choose a game",
                            detail: sports.detailError ?? "Select a matchup to pin its score and latest play to your widget.")
            }
            Text("ESPN · updates may be delayed").font(.system(size: 9)).foregroundStyle(Theme.inkTertiary)
        }
    }
}

struct SportsWidget: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var sports: SportsMonitor
    init(model: IslandModel) { self.model = model; self.sports = model.sports }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(title: "Following", count: nil)
                Spacer()
                Button("Choose game") { model.tab = .sports }
                    .font(Theme.Font.caption).foregroundStyle(Palette.blue).buttonStyle(.plain)
            }
            if !sports.enabled {
                SportsEmpty(title: "Sports is turned off", detail: "Enable sports in Settings → Features.")
                Button("Open settings") { model.openSettings?(.features) }.buttonStyle(.plain)
            } else if let game = sports.selectedGame {
                SportsScoreHeader(game: game)
                if let error = sports.detailError {
                    Text(error).font(Theme.Font.caption).foregroundStyle(Palette.amber)
                } else if let play = sports.plays.first {
                    Text(play.timeLabel).font(Theme.Font.number).foregroundStyle(Theme.inkTertiary)
                    Text(play.text).font(Theme.Font.body).foregroundStyle(Theme.inkSecondary).lineLimit(3)
                } else {
                    Text(sports.loading ? "Loading plays…" : game.state == "pre" ? "Waiting for tip-off or kickoff" : "Play-by-play unavailable")
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                }
                HStack {
                    Button("Play-by-play →") { model.tab = .sports }
                        .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Palette.blue)
                    Spacer()
                    Text("ESPN").font(.system(size: 9)).foregroundStyle(Theme.inkTertiary)
                }
            } else {
                SportsEmpty(title: sports.loading ? "Loading…" : "Follow a game",
                            detail: sports.detailError ?? "NBA, NFL, and big college football matchups. Choose one to see every play here.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if let game = sports.selectedGame {
                TeamMatchupBackground(game: game).clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
            } else { RoundedRectangle(cornerRadius: Theme.Radius.card).fill(Theme.surface) }
        }
    }
}

private struct SportsScoreHeader: View {
    let game: SportsGame
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(game.league.title).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text(game.status).font(Theme.Font.number)
                    .foregroundStyle(game.isLive ? Palette.green : Theme.inkSecondary).lineLimit(1)
            }
            HStack(spacing: 12) {
                teamScore(game.away)
                Text("–").font(Theme.Font.caption).foregroundStyle(Theme.inkTertiary)
                teamScore(game.home)
            }
            .accessibilityLabel("\(game.away.name) \(game.away.score), \(game.home.name) \(game.home.score), \(game.status)")
        }
    }

    private func teamScore(_ team: SportsTeam) -> some View {
        VStack(spacing: 5) {
            Capsule().fill(team.tint).frame(height: 3)
            HStack(spacing: 6) {
                Text(team.label).font(Theme.Font.headline).foregroundStyle(team.tint)
                Spacer(minLength: 0)
                Text(team.score).font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
            }
            .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct SportsEmpty: View {
    let title: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(Theme.Font.headline)
            Text(detail).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
