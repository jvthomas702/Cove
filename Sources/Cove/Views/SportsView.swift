import SwiftUI

extension SportsTeam {
    var tint: Color { Color(hex: accentHex) }
    var brandColor: Color { Color(hex: primaryHex ?? 0x71717A) }
}

/// The two teams' colors washed across a card, away on the left and home on the right, over the dark
/// surface: the look of a broadcast score bug, kept quiet enough for white text.
struct TeamMatchupBackground: View {
    let game: SportsGame
    var strength: Double = 0.22

    var body: some View {
        ZStack {
            Theme.surface
            LinearGradient(stops: [.init(color: game.away.brandColor.opacity(strength), location: 0),
                                   .init(color: .clear, location: 0.5),
                                   .init(color: game.home.brandColor.opacity(strength), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
        }
    }
}

/// The Sports tab: a grid of every game in the league, grouped Live, Upcoming and Final, or, once you
/// pick one, that game's scoreboard and play-by-play. Games switches back to the grid.
struct SportsPane: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var sports: SportsMonitor
    @State private var showingGames = false

    init(model: IslandModel) {
        self.model = model
        self.sports = model.sports
    }

    private var showsGrid: Bool { showingGames || model.config.sportsGameID == nil }

    var body: some View {
        VStack(spacing: 8) {
            toolbar
            if !sports.enabled {
                SportsEmpty(title: "Sports is turned off", detail: "Turn it on in Settings → Sports.")
                Button("Open settings") { model.openSettings?(.sports) }.buttonStyle(PillButtonStyle())
            } else if showsGrid {
                gameGrid.transition(.materialize)
            } else {
                FollowedScoresStrip(model: model)
                if let error = sports.followedSlateError, model.followedSportsGames.count > 1 {
                    Text(error).font(.system(size: 9)).foregroundStyle(Palette.amber)
                }
                SportsDetail(sports: sports)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.materialize)
            }
        }
        .animation(Theme.settle, value: showsGrid)
    }

    private var toolbar: some View {
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
            if sports.loading { ArcSpinner(color: Theme.inkSecondary, size: 11) }
            if model.config.sportsGameID != nil {
                Button {
                    showingGames.toggle()
                } label: {
                    Label(showingGames ? "Back to game" : "Games", systemImage: showingGames ? "sportscourt" : "square.grid.2x2")
                }
                .buttonStyle(PillButtonStyle())
                .accessibilityIdentifier("sports.games")
            }
            IconButton(systemImage: "star", size: 12, hit: 24) { model.openSettings?(.sports) }
                .help("Choose favorite teams").accessibilityLabel("Choose favorite teams")
            IconButton(systemImage: "arrow.clockwise", size: 12, hit: 24) { sports.refresh() }
                .help("Refresh games")
                .accessibilityLabel("Refresh games")
                .disabled(sports.loading || !sports.enabled)
        }
    }

    private struct GameSection: Identifiable {
        let title: String
        let games: [SportsGame]
        var id: String { title }
    }

    private var sections: [GameSection] {
        let games = model.visibleSportsGames
        return [GameSection(title: "Live", games: games.filter { $0.isLive }),
                GameSection(title: "Upcoming", games: games.filter { !$0.isLive && !$0.isFinal }),
                GameSection(title: "Final", games: games.filter { $0.isFinal })]
            .filter { !$0.games.isEmpty }
    }

    private var gameGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = sports.scoreboardError {
                Text(error).font(Theme.Font.caption).foregroundStyle(Palette.amber).fixedSize(horizontal: false, vertical: true)
            }
            if model.visibleSportsGames.isEmpty {
                SportsEmpty(title: sports.loading ? "Loading games…" : "No games right now",
                            detail: model.config.sportsLeague == .collegeFootball && model.config.sportsRankedOnly
                            ? "No Top 25 matchups in this slate. Turn off Top 25 to see every FBS game."
                            : "Check back for the next slate of games.")
            } else {
                ScrollView(.vertical) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 172), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(sections) { section in
                            Section {
                                ForEach(Array(section.games.enumerated()), id: \.element.id) { index, game in
                                    GameCard(game: game,
                                             pinned: game.id == model.config.sportsGameID,
                                             followed: model.config.sportsWatchedGames.contains(game.key),
                                             choose: { model.chooseSportsGame(game); showingGames = false },
                                             toggleFollow: { model.toggleWatchedGame(game) })
                                        .entrance(index)
                                }
                            } header: {
                                HStack(spacing: 5) {
                                    if section.title == "Live" { LiveDot() }
                                    SectionTitle(title: section.title, count: section.games.count)
                                    Spacer(minLength: 0)
                                }
                                .padding(.top, 2)
                            }
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.never)
                .accessibilityIdentifier("sports.gamePicker")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A pulsing red dot for games that are on.
struct LiveDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(Palette.red)
            .frame(width: 6, height: 6)
            .background {
                Circle().stroke(Palette.red.opacity(pulse ? 0 : 0.6), lineWidth: 1.5)
                    .scaleEffect(pulse ? 2.4 : 1)
            }
            .onAppear {
                guard !Theme.reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
            }
            .accessibilityHidden(true)
    }
}

/// A score card: when it is (or the clock), then each team on its own row with its logo and score, the
/// leader in white. The teams' colors wash across the card; the pinned game has an accent edge.
private struct GameCard: View {
    let game: SportsGame
    let pinned: Bool
    let followed: Bool
    let choose: () -> Void
    let toggleFollow: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.isTerminal ? 4 : 14, style: .continuous)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    if game.isLive { LiveDot() }
                    Text(game.statusLine())
                        .font(.system(size: 9.5, weight: .semibold, design: Theme.isTerminal ? .monospaced : .rounded))
                        .foregroundStyle(game.isLive ? Palette.red : Theme.inkSecondary)
                        .lineLimit(1)
                    if pinned {
                        Text("Pinned")
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Theme.accent.opacity(0.14)))
                    }
                    Spacer(minLength: 22)
                }
                row(game.away, against: game.home)
                row(game.home, against: game.away)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(TeamMatchupBackground(game: game, strength: hovering ? 0.3 : 0.2))
            .clipShape(shape)
            .overlay { shape.strokeBorder(pinned ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: pinned ? 1.2 : 0.75) }
            .contentShape(shape)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: hovering)
        .help("Show \(game.away.name) at \(game.home.name)")
        .accessibilityIdentifier("sports.game.\(game.id)")
        .overlay(alignment: .topTrailing) {
            Button(action: toggleFollow) {
                Image(systemName: followed ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(followed ? Palette.amber : Theme.inkTertiary)
                    .frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .padding(3)
            .help(followed ? "Unfollow game" : "Follow game")
            .accessibilityLabel(followed ? "Unfollow game" : "Follow game")
            .accessibilityIdentifier("sports.watch.\(game.id)")
        }
    }

    private func row(_ team: SportsTeam, against other: SportsTeam) -> some View {
        let started = game.state != "pre"
        let leading = started && (Int(team.score) ?? 0) >= (Int(other.score) ?? 0)
        return HStack(spacing: 8) {
            TeamLogo(team: team, size: 22)
            Text(team.label)
                .font(.system(size: 12.5, weight: leading || !started ? .semibold : .medium, design: Theme.isTerminal ? .monospaced : .rounded))
                .foregroundStyle(leading || !started ? Theme.ink : Theme.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if started {
                Text(team.score)
                    .font(.system(size: 17, weight: .bold, design: Theme.isTerminal ? .monospaced : .rounded).monospacedDigit())
                    .foregroundStyle(leading ? Theme.ink : Theme.inkSecondary)
                    .contentTransition(.numericText())
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
                Button("Open settings") { model.openSettings?(.sports) }.buttonStyle(PillButtonStyle())
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
                HStack(spacing: 5) {
                    if game.isLive { LiveDot() }
                    Text(game.statusLine()).font(Theme.Font.number)
                        .foregroundStyle(game.isLive ? Palette.red : Theme.inkSecondary).lineLimit(1)
                }
                Text(game.league.shortTitle).font(.system(size: 9, design: Theme.isTerminal ? .monospaced : .default))
                    .foregroundStyle(Theme.inkTertiary)
            }
            .frame(minWidth: 70)
            side(game.home, against: game.away, leading: false)
        }
        .padding(.horizontal, 12).frame(height: 54)
        .background(TeamMatchupBackground(game: game, strength: 0.28))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.75) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(game.away.name) \(game.away.score), \(game.home.name) \(game.home.score), \(game.status)")
    }

    private func side(_ team: SportsTeam, against other: SportsTeam, leading: Bool) -> some View {
        let trailing = game.state != "pre" && (Int(team.score) ?? 0) < (Int(other.score) ?? 0)
        let score = Text(game.state == "pre" ? "–" : team.score)
            .font(.system(size: 26, weight: .bold, design: Theme.isTerminal ? .monospaced : .rounded).monospacedDigit())
            .foregroundStyle(trailing ? Theme.inkSecondary : Theme.ink)
            .contentTransition(.numericText())
        let name = HStack(spacing: 7) {
            if leading { TeamLogo(team: team, size: 32) }
            Text(team.label).font(Theme.Font.headline).foregroundStyle(Theme.ink)
            if !leading { TeamLogo(team: team, size: 32) }
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
