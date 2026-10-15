import AppKit
import SwiftUI

/// A single row of matte tiles, like the reference. Gamecast stays one click away.
struct HomePane: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        GeometryReader { geometry in
            // A smaller display keeps the same tiles reachable without shrinking their text.
            let width = max(930, geometry.size.width)
            let space = width - 30
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    MatteMusicTile(model: model).frame(width: space * 0.23)
                    MatteSportsTile(model: model).frame(width: space * 0.32)
                    MatteContextTile(model: model).frame(width: space * 0.26)
                    AIConnectionsTile(model: model).frame(width: space * 0.19)
                }
                .frame(height: 140)
            }
            .scrollIndicators(.automatic)
        }
        .accessibilityIdentifier("home.matteDashboard")
    }
}

private struct MatteTile: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5) }
            .accessibilityElement(children: .contain)
    }
}

private struct MatteMusicTile: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                ZStack(alignment: .leading) {
                    Circle().fill(Color(hex: 0x0D0E12)).frame(width: 62, height: 62).offset(x: 16)
                        .overlay { Circle().stroke(Color.white.opacity(0.12), lineWidth: 1).frame(width: 44, height: 44).offset(x: 16) }
                    if let image = model.artwork {
                        Image(nsImage: image).resizable().scaledToFill()
                            .frame(width: 56, height: 66).clipShape(RoundedRectangle(cornerRadius: 9))
                    } else {
                        RoundedRectangle(cornerRadius: 9).fill(Theme.surfaceRaised)
                            .frame(width: 56, height: 66)
                            .overlay { Image(systemName: "music.note").font(.system(size: 22)).foregroundStyle(Theme.accent) }
                    }
                }.frame(width: 78, height: 66)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.nowPlaying?.title ?? "Nothing playing").font(Theme.Font.headline).lineLimit(2)
                    Text(model.nowPlaying?.artist ?? "Music · Spotify")
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    HStack(spacing: 2) {
                        mediaButton("backward.fill", label: "Previous track", command: "previous track")
                        mediaButton(model.nowPlaying?.isPlaying == true ? "pause.fill" : "play.fill",
                                    label: "Play or pause", command: "playpause")
                        mediaButton("forward.fill", label: "Next track", command: "next track")
                    }
                }
            }
            if let playing = model.nowPlaying {
                PlaybackBar(nowPlaying: playing, tint: Theme.accent)
            } else {
                Text("Start playback in your music app")
                    .font(.system(size: 10)).foregroundStyle(Theme.inkTertiary).lineLimit(1)
            }
        }
        .modifier(MatteTile())
        .accessibilityIdentifier("home.musicTile")
    }

    private func mediaButton(_ symbol: String, label: String, command: String) -> some View {
        IconButton(systemImage: symbol, size: 11, hit: 24) { model.media(command) }
            .accessibilityLabel(label).disabled(model.nowPlaying == nil)
    }
}

private struct MatteSportsTile: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var sports: SportsMonitor
    init(model: IslandModel) { self.model = model; self.sports = model.sports }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 4) {
                Image(systemName: "sportscourt.fill").foregroundStyle(Theme.accent)
                Text("Sports").font(Theme.Font.headline)
                Spacer(minLength: 0)
                if let game = sports.selectedGame, sports.enabled {
                    Text(game.isLive ? "LIVE" : game.isFinal ? "FINAL" : "NEXT")
                        .font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accent.opacity(0.12)))
                }
            }.font(Theme.Font.caption)
            if sports.enabled, let game = sports.selectedGame {
                HStack(spacing: 10) {
                    score(game.away, upcoming: game.state == "pre")
                    Text("–").foregroundStyle(Theme.inkTertiary)
                    score(game.home, upcoming: game.state == "pre")
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(game.status).font(Theme.Font.number).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                    Text(sports.detailError ?? sports.plays.first?.text ?? (game.state == "pre" ? "Waiting for kickoff or tip-off" : "Play-by-play unavailable"))
                        .font(.system(size: 10)).foregroundStyle(sports.detailError == nil ? Theme.inkSecondary : Palette.amber)
                        .lineLimit(1).help(sports.detailError ?? sports.plays.first?.text ?? "")
                }
            } else {
                Text(!sports.enabled ? "Sports is turned off" : sports.loading ? "Loading games…" : "Follow a game")
                    .font(Theme.Font.headline)
                Text(!sports.enabled ? "Enable sports in Settings" : sports.detailError ?? "NBA, NFL & college football")
                    .font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack {
                Button(sports.selectedGame == nil ? "Choose game →" : "Play-by-play →") { model.navigate(to: .sports) }
                    .font(Theme.Font.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
                    .accessibilityIdentifier("home.openGamecast")
                Spacer(minLength: 0)
                Text(sports.detailError == nil ? "ESPN" : "Updates paused")
                    .font(.system(size: 9)).foregroundStyle(Theme.inkTertiary)
            }
        }
        .modifier(MatteTile())
        .accessibilityIdentifier("home.sportsTile")
    }

    private func score(_ team: SportsTeam, upcoming: Bool) -> some View {
        HStack(spacing: 6) {
            TeamLogo(team: team, size: 24)
            Text(team.abbreviation).font(Theme.Font.headline).lineLimit(1)
            Spacer(minLength: 0)
            Text(upcoming ? "–" : team.score)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(team.name), \(upcoming ? "upcoming" : team.score)")
    }
}

private struct MatteContextTile: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.config.homeWidget {
            case .calendar:
                Text("Up next").font(Theme.Font.headline)
                if let event = model.schedule.nextEvent() {
                    Text(event.title).font(Theme.Font.body).lineLimit(2)
                    Text(IslandModel.relative(event.start)).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                } else { Text("No upcoming events").font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary) }
                Spacer(minLength: 0)
                Button("Schedule →") { model.navigate(to: .schedule) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
            case .focus:
                Text("Focus").font(Theme.Font.headline)
                if let end = model.focusEnd {
                    Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                        .font(.system(size: 28, weight: .medium).monospacedDigit())
                    Button("End session") { model.stopFocus() }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                } else {
                    Text("A little room to concentrate").font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                    Spacer(minLength: 0)
                    Button("Start 25 minutes") { model.startFocus(minutes: 25) }.buttonStyle(.plain).foregroundStyle(Theme.accent)
                }
            default:
                HStack {
                    Text("Activity").font(Theme.Font.headline)
                    if !model.activities.isEmpty {
                        Text("\(model.activities.count)").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.accent).padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.12)))
                    }
                    Spacer()
                }
                if model.activities.isEmpty {
                    Text(model.history.first?.title ?? "All quiet for now")
                        .font(Theme.Font.body).lineLimit(1)
                    Text(model.history.first?.body ?? "Connected tasks and notifications appear here")
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary).lineLimit(2)
                    Spacer(minLength: 0)
                    Button("Connections →") { model.openAIConnections() }
                        .buttonStyle(.plain).font(Theme.Font.caption).foregroundStyle(Theme.accent)
                } else {
                    ForEach(model.activities.prefix(2)) { activity in
                        Button {
                            if activity.agent.isAI {
                                model.selectedAIActivityID = activity.id
                                model.navigate(to: .ai)
                            } else { model.open(activity) }
                        } label: {
                            HStack(spacing: 7) {
                                AIAgentAvatar(activity: activity, showBuddy: model.config.buddy, size: 27)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(activity.agent.displayName).font(Theme.Font.headline)
                                        Spacer()
                                        Text(activity.phase ?? (activity.isLive ? "Working" : "Finished"))
                                            .font(.system(size: 9)).foregroundStyle(Theme.accent).lineLimit(1)
                                    }
                                    Text(activity.title).font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                                }.contentShape(Rectangle())
                            }
                        }.buttonStyle(.plain)
                        .accessibilityIdentifier("home.activity.\(activity.id)")
                    }
                }
            }
        }
        .modifier(MatteTile())
        .accessibilityIdentifier("home.activityTile")
    }
}

private struct AIConnectionsTile: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("AI connections", systemImage: "link").font(Theme.Font.headline)
            Text("Claude Code · Codex\nChatGPT · Gemini")
                .font(.system(size: 10)).foregroundStyle(Theme.inkSecondary).lineSpacing(3)
            Spacer(minLength: 0)
            Button("Set up AI →") { model.openAIConnections() }
                .font(Theme.Font.caption).foregroundStyle(Theme.accent).buttonStyle(.plain)
                .frame(height: 28).contentShape(Rectangle())
                .accessibilityIdentifier("home.connectAI")
        }.modifier(MatteTile())
            .accessibilityIdentifier("home.connectionsTile")
    }
}

/// Explicit shortcuts to macOS settings, rather than switches with guessed state.
struct DeviceSettingsMenu: View {
    var body: some View {
        Menu("Devices") {
            Button("Sound & volume…") { settings("com.apple.Sound-Settings.extension") }
            Button("Display & brightness…") { settings("com.apple.Displays-Settings.extension") }
            Button("Wi-Fi…") { settings("com.apple.wifi-settings-extension") }
            Button("AirDrop…") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"))
            }
        }
        .font(Theme.Font.caption).menuStyle(.borderlessButton).fixedSize()
        .help("Device settings").accessibilityIdentifier("device.settings")
    }
    private func settings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}
