import SwiftUI

struct SportsGamecastPane: View {
    @ObservedObject var sports: SportsMonitor
    var body: some View {
        Group {
            if let game = sports.selectedGame {
                SportsGamecastDetail(sports: sports, game: game).id(game.id)
            } else {
                SportsEmpty(title: sports.loading && sports.enabled ? "Loading your game…" : "Choose a game",
                            detail: sports.detailError ?? "Select a matchup to follow its score, plays, drives, and stats.")
            }
        }
    }
}

private enum GamecastMode: String, CaseIterable { case plays = "Plays", drives = "Drives", stats = "Stats" }

private struct SportsGamecastDetail: View {
    @ObservedObject var sports: SportsMonitor
    let game: SportsGame
    @State private var mode = GamecastMode.plays
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SportsScoreHeader(game: game)
            if let situation = sports.situation {
                HStack(spacing: 6) {
                    if let team = game.team(situation.teamID) { TeamLogo(team: team, size: 16); Text(team.abbreviation).foregroundStyle(team.tint) }
                    Text(situation.text).foregroundStyle(Theme.inkSecondary)
                }.font(Theme.Font.number)
            }
            if let error = sports.detailError {
                Text(error).font(Theme.Font.caption).foregroundStyle(Palette.amber)
            }
            HStack {
                Picker("Game detail", selection: $mode) {
                    ForEach(GamecastMode.allCases.filter { game.league != .nba || $0 != .drives }, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: game.league == .nba ? 150 : 210)
                .accessibilityIdentifier("sports.mode")
                Spacer(minLength: 0)
                if let url = game.gamecastURL {
                    Link("ESPN ↗", destination: url).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                        .help("Open the full ESPN Gamecast")
                }
            }
            Group {
                switch mode {
                case .plays: SportsTimeline(plays: sports.plays, game: game, loading: sports.loading)
                case .drives: SportsDrives(drives: sports.drives, plays: sports.plays, game: game)
                case .stats: SportsBoxScore(stats: sports.stats, leaders: sports.leaders, game: game)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            SportsFreshness(updated: sports.updatedAt, paused: sports.detailError != nil, live: game.isLive)
        }
    }
}

struct SportsPlayRow: View {
    let play: SportsPlay
    let game: SportsGame
    private var team: SportsTeam? { game.team(play.teamID) }
    private var tint: Color { team?.tint ?? Theme.inkSecondary }
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let team { TeamLogo(team: team, size: 22) }
            else { Image(systemName: "clock").font(.system(size: 11)).foregroundStyle(Theme.inkTertiary).frame(width: 22, height: 22) }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(play.timeLabel).foregroundStyle(Theme.inkTertiary)
                    if let badge = play.badge {
                        Text(badge).foregroundStyle(play.penalty ? Palette.amber : tint).lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill((play.penalty ? Palette.amber : tint).opacity(0.13)))
                    }
                    Spacer(minLength: 0)
                    if let score = play.score { Text(score).foregroundStyle(play.scoring ? tint : Theme.inkTertiary).monospacedDigit() }
                }.font(Theme.Font.number)
                if !play.context.isEmpty {
                    HStack {
                        Text(play.context)
                        Spacer(minLength: 0)
                        if let yards = play.yards { Text("\(yards > 0 ? "+" : "")\(yards) yd") }
                    }.font(Theme.Font.caption).foregroundStyle(tint)
                }
                Text(play.text).font(Theme.Font.body).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !play.athleteNames.isEmpty && !play.athleteNames.allSatisfy({ play.text.contains($0) }) {
                    Text(play.athleteNames.joined(separator: " · ")).font(.system(size: 9.5))
                        .foregroundStyle(Theme.inkTertiary).lineLimit(1)
                }
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(play.scoring ? tint.opacity(0.10) : Theme.surface))
        .overlay(alignment: .leading) {
            if play.scoring { Capsule().fill(tint).frame(width: 2).padding(.vertical, 9) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("sports.play.\(play.id)")
    }
}

private struct SportsTimeline: View {
    let plays: [SportsPlay]
    let game: SportsGame
    let loading: Bool
    @State private var period: Int?
    @State private var scoringOnly = false
    @State private var scrollID: String?
    private var periods: [Int] { Set(plays.map(\.period).filter { $0 > 0 }).sorted() }
    private var visible: [SportsPlay] { SportsPlayFilter.apply(plays, period: period, scoringOnly: scoringOnly) }
    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    SectionTitle(title: "Play-by-play", count: visible.count)
                    Spacer(minLength: 0)
                    Picker("Quarter", selection: $period) {
                        Text("All quarters").tag(Int?.none)
                        ForEach(periods, id: \.self) { Text(SportsPlayFilter.periodName($0)).tag(Optional($0)) }
                    }.labelsHidden().pickerStyle(.menu).frame(width: 105)
                        .accessibilityIdentifier("sports.period")
                    Toggle("Scoring", isOn: $scoringOnly).toggleStyle(.checkbox).font(Theme.Font.caption)
                        .accessibilityIdentifier("sports.scoring")
                    Button {
                        period = nil; scoringOnly = false
                        if let first = plays.first { scrollID = first.id; proxy.scrollTo(first.id, anchor: .top) }
                    } label: { Image(systemName: "arrow.up.to.line") }
                    .buttonStyle(.plain).help("Jump to the latest play").accessibilityLabel("Latest play")
                }
                if plays.isEmpty {
                    SportsEmpty(title: loading ? "Loading plays…" : "No plays yet",
                                detail: game.state == "pre" ? "Play-by-play appears once the game starts." : "ESPN has not supplied a play-by-play feed for this game.")
                } else if visible.isEmpty {
                    SportsEmpty(title: "No matching plays", detail: "Choose another quarter or turn off Scoring.")
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(visible) { play in SportsPlayRow(play: play, game: game).id(play.id) }
                        }.scrollTargetLayout()
                    }
                    .scrollPosition(id: $scrollID, anchor: .top)
                    .accessibilityIdentifier("sports.plays")
                }
            }
            .onChange(of: period) { _, _ in scrollID = visible.first?.id }
            .onChange(of: scoringOnly) { _, _ in scrollID = visible.first?.id }
        }
    }
}

private struct SportsDrives: View {
    let drives: [SportsDrive]
    let plays: [SportsPlay]
    let game: SportsGame
    @State private var expanded: Set<String> = []
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionTitle(title: "Drive chart", count: drives.count)
            if drives.isEmpty {
                SportsEmpty(title: "No drives yet", detail: "Drive summaries appear when ESPN supplies them.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(drives) { drive in
                            DisclosureGroup(isExpanded: Binding(get: { expanded.contains(drive.id) }, set: { if $0 { expanded.insert(drive.id) } else { expanded.remove(drive.id) } })) {
                                let drivePlays = plays.filter { drive.playIDs.contains($0.id) }
                                ForEach(drivePlays) { play in SportsPlayRow(play: play, game: game) }
                            } label: {
                                HStack(spacing: 8) {
                                    if let team = game.team(drive.teamID) { TeamLogo(team: team, size: 24) }
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(drive.result).font(Theme.Font.headline)
                                            .foregroundStyle(drive.scoring ? (game.team(drive.teamID)?.tint ?? Theme.accent) : Theme.ink)
                                        Text(drive.summary).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                                    }
                                    Spacer(minLength: 0)
                                    Text([drive.period > 0 ? SportsPlayFilter.periodName(drive.period) : "", drive.clock].filter { !$0.isEmpty }.joined(separator: " · "))
                                        .font(Theme.Font.number).foregroundStyle(Theme.inkTertiary)
                                    if drive.current { Circle().fill(Theme.accent).frame(width: 5, height: 5) }
                                }
                            }
                            .padding(9).background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                            .accessibilityIdentifier("sports.drive.\(drive.id)")
                        }
                    }
                }.accessibilityIdentifier("sports.drives")
            }
        }
        .onAppear { if let drive = drives.first(where: \.current) { expanded.insert(drive.id) } }
    }
}

private struct SportsBoxScore: View {
    let stats: [SportsStat]
    let leaders: [SportsLeader]
    let game: SportsGame
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let count = max(game.away.periodScores.count, game.home.periodScores.count)
                if count > 0 {
                    SectionTitle(title: "By quarter")
                    ScrollView(.horizontal) {
                        Grid(horizontalSpacing: 13, verticalSpacing: 7) {
                            GridRow {
                                Text("").frame(width: 36)
                                ForEach(0..<count, id: \.self) { Text(SportsPlayFilter.periodName($0 + 1)) }
                                Text("T")
                            }.foregroundStyle(Theme.inkTertiary)
                            periodRow(game.away, count: count)
                            periodRow(game.home, count: count)
                        }.font(Theme.Font.number)
                    }
                }
                if !stats.isEmpty {
                    SectionTitle(title: "Team stats")
                    HStack { Text(game.away.abbreviation).foregroundStyle(game.away.tint); Spacer(); Text(game.home.abbreviation).foregroundStyle(game.home.tint) }.font(Theme.Font.headline)
                    VStack(spacing: 0) {
                        ForEach(stats) { stat in
                            HStack(spacing: 8) {
                                Text(stat.values[game.away.id ?? ""] ?? "–").frame(width: 70, alignment: .leading).foregroundStyle(game.away.tint)
                                Text(stat.label).font(Theme.Font.caption).frame(maxWidth: .infinity).multilineTextAlignment(.center).foregroundStyle(Theme.inkSecondary)
                                Text(stat.values[game.home.id ?? ""] ?? "–").frame(width: 70, alignment: .trailing).foregroundStyle(game.home.tint)
                            }.font(Theme.Font.number).padding(.vertical, 7)
                                .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
                        }
                    }
                }
                if !leaders.isEmpty {
                    SectionTitle(title: "Game leaders")
                    ForEach(leaders) { leader in
                        HStack(spacing: 8) {
                            if let team = game.team(leader.teamID) { TeamLogo(team: team, size: 22) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(leader.name).font(Theme.Font.headline)
                                Text(leader.category).font(Theme.Font.caption).foregroundStyle(Theme.inkTertiary)
                            }
                            Spacer(minLength: 0)
                            Text(leader.value).font(Theme.Font.number).foregroundStyle(game.team(leader.teamID)?.tint ?? Theme.ink)
                        }
                    }
                }
                if count == 0, stats.isEmpty, leaders.isEmpty {
                    SportsEmpty(title: "Stats unavailable", detail: "The box score will appear when ESPN publishes it.")
                }
            }.padding(.horizontal, 2)
        }.accessibilityIdentifier("sports.stats")
    }
    private func periodRow(_ team: SportsTeam, count: Int) -> some View {
        GridRow {
            Text(team.abbreviation).foregroundStyle(team.tint)
            ForEach(0..<count, id: \.self) { index in Text(index < team.periodScores.count ? team.periodScores[index] : "–") }
            Text(team.score).bold()
        }
    }
}

private struct SportsFreshness: View {
    let updated: Date?
    let paused: Bool
    let live: Bool
    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            HStack(spacing: 5) {
                let age = updated.map { max(0, Int(context.date.timeIntervalSince($0))) }
                Circle().fill(paused || (live && (age ?? 0) > 30) ? Palette.amber : live ? Theme.accent : Theme.inkTertiary).frame(width: 4, height: 4)
                Text(paused ? "Updates paused" : age.map { "Updated \($0 < 60 ? "\($0)s" : "\($0 / 60)m") ago" } ?? "Waiting for data")
                Spacer(minLength: 0)
                Text(live ? "ESPN · checks every 10s · may be delayed" : "ESPN · may be delayed")
            }.font(.system(size: 9)).foregroundStyle(Theme.inkTertiary)
        }
    }
}
