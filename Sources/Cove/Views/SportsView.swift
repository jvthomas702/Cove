import SwiftUI

extension SportsTeam {
    var tint: Color { Color(hex: accentHex) }
    var brandColor: Color { Color(hex: primaryHex ?? 0x71717A) }
}

private struct TeamMatchupBackground: View {
    let game: SportsGame
    var body: some View {
        Theme.surface
    }
}

/// A dedicated, scrollable game picker. Choosing a game pins it to the Home widget and notch.
struct SportsPane: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var sports: SportsMonitor
    @State private var showingGames = false

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
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("sports.league")
                .frame(width: 305)
                if model.config.sportsLeague == .collegeFootball {
                    Toggle("Top 25", isOn: Binding(get: { model.config.sportsRankedOnly }, set: {
                        var config = model.config
                        config.sportsRankedOnly = $0
                        model.applyConfig?(config)
                    }))
                    .toggleStyle(.checkbox)
                    .accessibilityIdentifier("sports.top25")
                    .font(Theme.Font.caption)
                    .help("Games featuring at least one Top 25 team")
                }
                Spacer(minLength: 0)
                Button {
                    showingGames.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("Games")
                        Image(systemName: showingGames ? "chevron.up" : "chevron.down")
                    }.font(Theme.Font.caption)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.accent)
                .accessibilityIdentifier("sports.games")
                IconButton(systemImage: "star", size: 12, hit: 24) { model.openSettings?(.features) }
                    .help("Choose favorite teams").accessibilityLabel("Choose favorite teams")
                if sports.loading { ProgressView().controlSize(.mini) }
                IconButton(systemImage: "arrow.clockwise", size: 12, hit: 24) { sports.refresh() }
                    .help("Refresh games")
                    .accessibilityLabel("Refresh games")
                    .disabled(sports.loading || !sports.enabled)
            }
            if !sports.enabled {
                SportsEmpty(title: "Sports is turned off", detail: "Enable it in Settings → Features.")
                Button("Open settings") { model.openSettings?(.features) }.buttonStyle(PillButtonStyle())
            } else {
                if showingGames || model.config.sportsGameID == nil {
                    gameList.frame(height: 90)
                }
                FollowedScoresStrip(model: model)
                if let error = sports.followedSlateError, model.followedSportsGames.count > 1 {
                    Text(error).font(.system(size: 9)).foregroundStyle(Palette.amber)
                }
                SportsDetail(sports: sports)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 6) {
                        ForEach(model.visibleSportsGames) { game in
                            VStack(spacing: 3) {
                            Button { model.chooseSportsGame(game); showingGames = false } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        HStack(spacing: 5) {
                                            TeamLogo(team: game.away, size: 19)
                                            Text(game.away.label).foregroundStyle(game.away.tint)
                                            Text("@").foregroundStyle(Theme.inkTertiary)
                                            Text(game.home.label).foregroundStyle(game.home.tint)
                                            TeamLogo(team: game.home, size: 19)
                                        }
                                        .font(Theme.Font.headline).lineLimit(1).minimumScaleFactor(0.8)
                                        Spacer(minLength: 0)
                                        if game.id == model.config.sportsGameID {
                                            Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Theme.accent)
                                        }
                                    }
                                    HStack {
                                        Text(game.state == "pre" ? "" : "\(game.away.score)–\(game.home.score)")
                                            .font(Theme.Font.number)
                                        Text(game.status).font(Theme.Font.caption)
                                            .foregroundStyle(game.isLive ? Theme.accent : Theme.inkSecondary)
                                            .lineLimit(1)
                                    }
                                }
                                .padding(9)
                                .frame(width: 180, alignment: .leading)
                                .background { TeamMatchupBackground(game: game).clipShape(RoundedRectangle(cornerRadius: 12)) }
                                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(game.id == model.config.sportsGameID ? game.away.tint.opacity(0.65) : Theme.hairline, lineWidth: 1) }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Follow \(game.away.name) at \(game.home.name)")
                            .accessibilityIdentifier("sports.game.\(game.id)")
                            Button(model.config.sportsWatchedGames.contains(game.key) ? "Unfollow game" : "Follow game") { model.toggleWatchedGame(game) }
                                .font(.system(size: 9)).foregroundStyle(Theme.accent).buttonStyle(.plain)
                                .accessibilityIdentifier("sports.watch.\(game.id)")
                            }
                        }
                    }.padding(.vertical, 2)
                }
                .accessibilityIdentifier("sports.gamePicker")
            }
        }
    }
}

private struct SportsDetail: View {
    @ObservedObject var sports: SportsMonitor
    var body: some View { SportsGamecastPane(sports: sports) }
}

struct SportsWidget: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var sports: SportsMonitor
    init(model: IslandModel) { self.model = model; self.sports = model.sports }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                SectionTitle(title: "Following", count: nil)
                Spacer()
                Button("Choose game") { model.tab = .sports }
                    .buttonStyle(PillButtonStyle())
            }
            if !sports.enabled {
                SportsEmpty(title: "Sports is turned off", detail: "Enable sports in Settings → Features.")
                Button("Open settings") { model.openSettings?(.features) }.buttonStyle(PillButtonStyle())
            } else if let game = sports.selectedGame {
                SportsScoreHeader(game: game)
                FollowedScoresStrip(model: model)
                if let error = sports.detailError {
                    Text(error).font(Theme.Font.caption).foregroundStyle(Palette.amber)
                } else if let play = sports.plays.first {
                    HStack {
                        if let team = game.team(play.teamID) { TeamLogo(team: team, size: 16) }
                        Text(play.timeLabel).font(Theme.Font.number).foregroundStyle(Theme.inkTertiary)
                        Spacer(minLength: 0)
                        if let badge = play.badge { Text(badge).font(Theme.Font.number).foregroundStyle(game.team(play.teamID)?.tint ?? Theme.accent).lineLimit(1) }
                    }
                    if !play.context.isEmpty { Text(play.context).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1) }
                    Text(play.text).font(Theme.Font.body).foregroundStyle(Theme.inkSecondary).lineLimit(3)
                } else {
                    Text(sports.loading ? "Loading plays…" : game.state == "pre" ? "Waiting for tip-off or kickoff" : "Play-by-play unavailable")
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                }
                HStack {
                    Button("Play-by-play") { model.tab = .sports }
                        .buttonStyle(PillButtonStyle())
                    Spacer()
                    Text(game.isLive ? "ESPN · 10s updates" : "ESPN").font(.system(size: 9)).foregroundStyle(Theme.inkTertiary)
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

struct SportsScoreHeader: View {
    let game: SportsGame
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(game.league.title).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text(game.status).font(Theme.Font.number)
                    .foregroundStyle(game.isLive ? Theme.accent : Theme.inkSecondary).lineLimit(1)
            }
            HStack(spacing: 12) {
                teamScore(game.away)
                Text("–").font(Theme.Font.caption).foregroundStyle(Theme.inkTertiary)
                teamScore(game.home)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(game.away.name) \(game.away.score), \(game.home.name) \(game.home.score), \(game.status)")
        }
    }

    private func teamScore(_ team: SportsTeam) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 7) {
                TeamLogo(team: team, size: 34)
                Text(team.label).font(Theme.Font.headline).foregroundStyle(team.tint)
                Spacer(minLength: 0)
                Text(team.score).font(.system(size: 20, weight: .bold, design: .rounded).monospacedDigit())
            }
            .lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

struct SportsEmpty: View {
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
