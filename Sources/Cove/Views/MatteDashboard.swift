import AppKit
import SwiftUI

/// Two matte tiles at most: music, plus the live game if there is one, or else recent activity.
/// AI connections live in the AI tab and the header, so Home stays uncluttered on a narrow island.
struct HomePane: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var sports: SportsMonitor
    init(model: IslandModel) { self.model = model; self.sports = model.sports }

    private var showsGame: Bool {
        guard sports.enabled, let game = sports.selectedGame else { return false }
        return !game.isFinal
    }

    var body: some View {
        HStack(spacing: 10) {
            MatteMusicTile(model: model).frame(maxWidth: .infinity).entrance(0)
            Group {
                if model.showsTimerTile {
                    QuickTimerTile(model: model).frame(maxWidth: .infinity)
                } else if showsGame {
                    MatteSportsTile(model: model).frame(maxWidth: .infinity)
                } else {
                    MatteContextTile(model: model).frame(maxWidth: .infinity)
                }
            }
            .transition(.materialize)
            .entrance(1)
        }
        .frame(height: 128)
        .accessibilityElement(children: .contain)
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

    private var tint: Color { model.accent ?? model.nowPlaying?.appTint ?? Theme.accent }
    private var playing: Bool { model.nowPlaying?.isPlaying == true }

    var body: some View {
        let np = model.nowPlaying
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                EqualizerBars(playing: playing, color: .white.opacity(0.85))
                    .scaleEffect(0.55, anchor: .leading).frame(width: 12, height: 9, alignment: .leading)
                Text(np == nil ? "Not playing" : (np?.bundleID == "com.spotify.client" ? "Spotify" : "Music"))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .textCase(.uppercase)
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                artwork
                VStack(alignment: .leading, spacing: 2) {
                    Text(np?.title ?? "Nothing playing")
                        .font(.system(size: 12.5, weight: .semibold, design: Theme.isTerminal ? .monospaced : .default))
                        .foregroundStyle(.white).lineLimit(1)
                    Text(np?.artist ?? "Play something in Music or Spotify")
                        .font(Theme.Font.caption).foregroundStyle(Color.white.opacity(0.62)).lineLimit(1)
                }
                .help(np.map { "\($0.title) — \($0.artist)" } ?? "")
                Spacer(minLength: 4)
                HStack(spacing: 6) {
                    GlassIconButton(systemImage: "backward.fill", size: 9, diameter: 24) { model.media("previous track") }
                        .help("Previous track").accessibilityLabel("Previous track")
                    GlassIconButton(systemImage: playing ? "pause.fill" : "play.fill", size: 12, diameter: 32, prominent: true) {
                        model.media("playpause")
                    }
                    .help(playing ? "Pause" : "Play").accessibilityLabel("Play or pause")
                    GlassIconButton(systemImage: "forward.fill", size: 9, diameter: 24) { model.media("next track") }
                        .help("Next track").accessibilityLabel("Next track")
                }
                .disabled(np == nil)
                .layoutPriority(1)
            }
            if let np {
                PlaybackBar(nowPlaying: np, tint: .white.opacity(0.9), track: .white.opacity(0.16))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LiquidGlassBackground(artwork: model.artwork, tint: tint, cornerRadius: 18, flowing: playing))
        .animation(.easeInOut(duration: 0.6), value: model.accent)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.musicTile")
    }

    private var artwork: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Group {
            if let image = model.artwork {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.white.opacity(0.06)
                    Image(systemName: "music.note").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                }
            }
        }
        .frame(width: 50, height: 50)
        .clipShape(shape)
        .overlay { shape.strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.45), radius: 8, y: 4)
        .scaleEffect(playing || model.nowPlaying == nil ? 1 : 0.92)
        .animation(Theme.morph, value: playing)
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
                // One line: the game clock, or why updates stopped. The latest play is a click away.
                Text(sports.detailError ?? game.status)
                    .font(Theme.Font.number).foregroundStyle(sports.detailError == nil ? Theme.inkSecondary : Palette.amber)
                    .lineLimit(1).help(sports.detailError ?? sports.plays.first?.text ?? "")
            } else {
                Text(!sports.enabled ? "Sports is turned off" : sports.loading ? "Loading games…" : "Follow a game")
                    .font(Theme.Font.headline)
                Text(!sports.enabled ? "Enable sports in Settings" : sports.detailError ?? "NBA, NFL & college football")
                    .font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            HStack {
                Button(sports.selectedGame == nil ? "Choose game" : "Play-by-play") { model.navigate(to: .sports) }
                    .buttonStyle(PillButtonStyle())
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
                Button("Schedule") { model.navigate(to: .schedule) }.buttonStyle(PillButtonStyle())
            case .focus:
                Text("Focus").font(Theme.Font.headline)
                if let timer = model.timer {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(QuickTimer.clock(timer.remaining(at: context.date)))
                            .font(.system(size: 28, weight: .medium).monospacedDigit())
                    }
                    Button("End session") { model.stopFocus() }.buttonStyle(PillButtonStyle(tint: Palette.red))
                } else {
                    Text("A little room to concentrate").font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                    Spacer(minLength: 0)
                    Button("Start 25 min") { model.startFocus(minutes: 25) }.buttonStyle(PillButtonStyle())
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
                    Button("Connections") { model.openAIConnections() }
                        .buttonStyle(PillButtonStyle())
                } else {
                    ForEach(model.activities.prefix(2)) { activity in
                        HStack(spacing: 6) {
                            Button {
                                if activity.agent.isAI {
                                    model.selectAIActivity(activity)
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
                            if model.ciActionsAvailable(activity.id) {
                                CIActionButtons(model: model, activityID: activity.id)
                            }
                        }
                    }
                }
            }
        }
        .modifier(MatteTile())
        .accessibilityIdentifier("home.activityTile")
    }
}

/// Re-run on a failed CI run, Run <deploy workflow> on a passed one, and their progress in place of the button.
struct CIActionButtons: View {
    @ObservedObject var model: IslandModel
    let activityID: String

    var body: some View {
        if let state = model.ciActionStates[activityID] {
            HStack(spacing: 4) {
                switch state {
                case .working: ArcSpinner(color: Theme.accent, size: 9)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green)
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.red)
                }
                Text(state.label).lineLimit(1)
            }
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.inkSecondary)
            .frame(maxWidth: 110, alignment: .trailing)
            .help(detail(state))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ci.status")
        } else if let run = model.ciRuns[activityID] {
            if run.state == .failed {
                Button { model.ciRerun(activityID) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .bold))
                        Text("Re-run")
                    }
                }
                .buttonStyle(PillButtonStyle(compact: true))
                .fixedSize()
                .help("Re-run the failed jobs of \(run.workflow) on \(run.branch)")
                .accessibilityIdentifier("ci.rerun")
            } else if run.state == .passed, let workflow = model.ciDeploys[activityID]?.first {
                Button { model.ciDeploy(activityID, workflow: workflow) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "paperplane.fill").font(.system(size: 9, weight: .bold))
                        Text("Run \(workflow.name)")
                    }
                }
                .buttonStyle(PillButtonStyle(compact: true))
                .frame(maxWidth: 120)
                .help("Start \(workflow.name) (\(workflow.fileName)) on \(run.branch)")
                .accessibilityIdentifier("ci.deploy")
            }
        }
    }

    private func detail(_ state: CIActionState) -> String {
        if case .failed(let message) = state { return message }
        return state.label
    }
}

/// Quick timers: 5 / 10 / 25 minute chips and a field for "3", "90s", "1h 15m" or "12:30";
/// while one runs, its countdown with Pause and Cancel.
private struct QuickTimerTile: View {
    @ObservedObject var model: IslandModel
    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var typing: Bool

    private static let presets = [5, 10, 25]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let timer = model.timer { running(timer) } else { picker }
        }
        .modifier(MatteTile())
        .accessibilityIdentifier("home.timerTile")
        .onChange(of: typing) { _, active in if active { model.openByClick() } }
    }

    private var picker: some View {
        Group {
            HStack(spacing: 5) {
                Image(systemName: "timer").foregroundStyle(Theme.accent)
                Text(model.config.homeWidget == .focus ? "Focus" : "Timer").font(Theme.Font.headline)
                Spacer(minLength: 0)
                if model.timerPickerOpen {
                    IconButton(systemImage: "xmark", size: 8, hit: 20) { model.timerPickerOpen = false }
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel("Close timer").accessibilityIdentifier("timer.close")
                }
            }
            HStack(spacing: 5) {
                ForEach(Self.presets, id: \.self) { minutes in
                    ChipButton(title: "\(minutes) min", tint: Theme.accent) {
                        model.startTimer(seconds: TimeInterval(minutes * 60),
                                         label: model.config.homeWidget == .focus ? "Focus" : "Timer")
                    }
                    .accessibilityIdentifier("timer.preset.\(minutes)")
                }
            }
            HStack(spacing: 6) {
                TextField("90s, 1h 15m, 12:30", text: $draft)
                    .textFieldStyle(.plain).font(Theme.Font.body)
                    .padding(.horizontal, 9).frame(height: 24)
                    .background(Capsule().fill(Theme.surfaceRaised))
                    .overlay { if invalid { Capsule().strokeBorder(Palette.red.opacity(0.7), lineWidth: 1) } }
                    .focused($typing)
                    .onSubmit(start)
                    .onChange(of: draft) { _, _ in invalid = false }
                    .accessibilityIdentifier("timer.field")
                Button("Start", action: start)
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("timer.start")
            }
            Text(hint)
                .font(.system(size: 9.5)).foregroundStyle(invalid ? Palette.red : Theme.inkTertiary).lineLimit(1)
        }
    }

    private var hint: String {
        if invalid { return "Try 3, 90s, 1h 15m or 12:30" }
        if let seconds = QuickTimer.parse(draft) { return QuickTimer.name(seconds) }
        return "Minutes, or a time to count down to"
    }

    private func running(_ timer: QuickTimer) -> some View {
        Group {
            HStack(spacing: 5) {
                Text(timer.label).font(Theme.Font.headline)
                Spacer(minLength: 0)
                if let end = timer.endDate {
                    Text("Ends \(end.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary).lineLimit(1)
                } else {
                    Text("Paused").font(Theme.Font.caption).foregroundStyle(Theme.inkSecondary)
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 10) {
                    ProgressRing(progress: timer.fractionLeft(at: context.date),
                                 color: timer.isPaused ? Theme.inkSecondary : Theme.accent, size: 30, lineWidth: 2)
                    Text(QuickTimer.clock(timer.remaining(at: context.date)))
                        .font(.system(size: 26, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(timer.isPaused ? Theme.inkSecondary : Theme.ink)
                        .accessibilityIdentifier("timer.remaining")
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                if timer.isPaused {
                    Button { model.resumeTimer() } label: { Label("Resume", systemImage: "play.fill") }
                        .buttonStyle(PillButtonStyle())
                        .accessibilityIdentifier("timer.resume")
                } else {
                    Button { model.pauseTimer() } label: { Label("Pause", systemImage: "pause.fill") }
                        .buttonStyle(PillButtonStyle())
                        .accessibilityIdentifier("timer.pause")
                }
                Button { model.cancelTimer() } label: { Label("Cancel", systemImage: "xmark") }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier("timer.cancel")
            }
            .labelStyle(.titleAndIcon)
        }
    }

    private func start() {
        if model.startTimer(text: draft) {
            draft = ""
            typing = false
        } else {
            invalid = true
        }
    }
}

/// Explicit shortcuts to macOS settings, rather than switches with guessed state.
struct DeviceSettingsMenu: View {
    var body: some View {
        Menu {
            Button("Sound & volume…") { settings("com.apple.Sound-Settings.extension") }
            Button("Display & brightness…") { settings("com.apple.Displays-Settings.extension") }
            Button("Wi-Fi…") { settings("com.apple.wifi-settings-extension") }
            Button("AirDrop…") {
                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app"))
            }
        } label: {
            Image(systemName: "slider.horizontal.3").font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .frame(width: 28, height: 28)
        .background(Circle().strokeBorder(Theme.accent.opacity(Theme.buttonLook == .outline ? 0.3 : 0), lineWidth: 1).background(Circle().fill(Theme.accent.opacity(Theme.buttonLook == .tinted ? 0.14 : 0))))
        .background { if Theme.buttonLook == .glass && !Theme.isTerminal { Circle().fill(Color.white.opacity(0.06)).overlay(Circle().strokeBorder(Theme.glassRim, lineWidth: 0.75)) } }
        .help("Device settings").accessibilityLabel("Device settings").accessibilityIdentifier("device.settings")
    }
    private func settings(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}
