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
                    ForEach(SportsLeague.allCases, id: \.self) { Text($0.shortTitle).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("sports.league")
                .frame(width: 160)
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
                    Label("Games", systemImage: showingGames ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(PillButtonStyle())
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
                    gameList.frame(height: 78)
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
                            GameCard(game: game,
                                     pinned: game.id == model.config.sportsGameID,
                                     followed: model.config.sportsWatchedGames.contains(game.key),
                                     choose: { model.chooseSportsGame(game); showingGames = false },
                                     toggleFollow: { model.toggleWatchedGame(game) })
                        }
                    }.padding(.vertical, 2)
                }
                .accessibilityIdentifier("sports.gamePicker")
            }
        }
    }
}

/// A scoreboard card: away and home on their own rows with scores at the right, the clock on top,
/// and a star to follow the game. Choosing the card pins it to Home and the notch.
private struct GameCard: View {
    let game: SportsGame
    let pinned: Bool
    let followed: Bool
    let choose: () -> Void
    let toggleFollow: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: choose) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        if game.isLive { Circle().fill(Palette.red).frame(width: 5, height: 5) }
                        Text(game.isLive ? game.status : game.isFinal ? "Final" : game.status)
                            .font(.system(size: 9, weight: .semibold, design: Theme.isTerminal ? .monospaced : .rounded))
                            .foregroundStyle(game.isLive ? Theme.ink : Theme.inkTertiary).lineLimit(1)
                    }
                    .padding(.trailing, 20)
                    row(game.away, against: game.home)
                    row(game.home, against: game.away)
                }
                .padding(.horizontal, 9).padding(.vertical, 7)
                .frame(width: 150, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(pinned ? Theme.surfaceRaised : Theme.surface))
                .overlay { RoundedRectangle(cornerRadius: Theme.Radius.row).strokeBorder(pinned ? Theme.accent.opacity(0.55) : Theme.hairline, lineWidth: 1) }
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .help("Show \(game.away.name) at \(game.home.name)")
            .accessibilityIdentifier("sports.game.\(game.id)")
            Button(action: toggleFollow) {
                Image(systemName: followed ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(followed ? Palette.amber : Theme.inkTertiary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .padding(3)
            .help(followed ? "Unfollow game" : "Follow game")
            .accessibilityLabel(followed ? "Unfollow game" : "Follow game")
            .accessibilityIdentifier("sports.watch.\(game.id)")
        }
    }

    private func row(_ team: SportsTeam, against other: SportsTeam) -> some View {
        let winning = game.state != "pre" && (Int(team.score) ?? 0) >= (Int(other.score) ?? 0)
        return HStack(spacing: 6) {
            TeamLogo(team: team, size: 16)
            Text(team.label).font(Theme.Font.headline).foregroundStyle(Theme.ink).lineLimit(1)
            Spacer(minLength: 0)
            if game.state != "pre" {
                Text(team.score)
                    .font(.system(size: 13, weight: .bold, design: Theme.isTerminal ? .monospaced : .rounded).monospacedDigit())
                    .foregroundStyle(winning ? Theme.ink : Theme.inkSecondary)
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

/// One scoreboard row, like a TV score bug: away on the left, home on the right, clock in the middle.
struct SportsScoreHeader: View {
    let game: SportsGame
    var body: some View {
        HStack(spacing: 10) {
            side(game.away, against: game.home, leading: true)
            VStack(spacing: 2) {
                HStack(spacing: 4) {
                    if game.isLive { Circle().fill(Palette.red).frame(width: 5, height: 5) }
                    Text(game.isFinal ? "Final" : game.status).font(Theme.Font.number)
                        .foregroundStyle(game.isLive ? Theme.ink : Theme.inkSecondary).lineLimit(1)
                }
                Text(game.league.shortTitle).font(.system(size: 9, design: Theme.isTerminal ? .monospaced : .default))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .frame(minWidth: 70)
            side(game.home, against: game.away, leading: false)
        }
        .padding(.horizontal, 10).frame(height: 44)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Theme.surface))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(game.away.name) \(game.away.score), \(game.home.name) \(game.home.score), \(game.status)")
    }

    private func side(_ team: SportsTeam, against other: SportsTeam, leading: Bool) -> some View {
        let trailing = game.state != "pre" && (Int(team.score) ?? 0) < (Int(other.score) ?? 0)
        let score = Text(game.state == "pre" ? "–" : team.score)
            .font(.system(size: 22, weight: .bold, design: Theme.isTerminal ? .monospaced : .rounded).monospacedDigit())
            .foregroundStyle(trailing ? Theme.inkSecondary : Theme.ink)
        let name = HStack(spacing: 6) {
            if leading { TeamLogo(team: team, size: 26) }
            Text(team.label).font(Theme.Font.headline).foregroundStyle(Theme.ink)
            if !leading { TeamLogo(team: team, size: 26) }
        }
        return HStack(spacing: 8) {
            if leading { name; Spacer(minLength: 0); score } else { score; Spacer(minLength: 0); name }
        }
        .lineLimit(1).minimumScaleFactor(0.75)
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
