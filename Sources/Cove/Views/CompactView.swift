import SwiftUI

/// Live-activity state: content sits in the two "wings" either side of the physical notch,
/// like the iPhone's compact leading/trailing views. Each wing holds one glanceable thing.
struct CompactView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let wing = model.compactWing - IslandModel.ear
        HStack(spacing: 0) {
            leading
                .frame(width: wing - 8, alignment: isWide ? .leading : .center)
                .padding(.leading, 8)
            Color.clear.frame(width: model.notchSize.width)
            trailing
                .frame(width: wing - 8, alignment: isWide ? .trailing : .center)
                .padding(.trailing, 8)
        }
        .frame(height: model.notchSize.height)
        .contentShape(Rectangle())
        .onTapGesture { model.openByClick() }
        .animation(Theme.snappy, value: model.compactItem)
    }

    private var isWide: Bool { model.compactWing > IslandModel.wing }

    /// Nori's mood when the leading wing shows Nori. One `Buddy` for all of these keeps it the same view
    /// as the state changes, so it springs from one face to the next instead of being swapped out.
    private var buddyMood: BuddyMood? {
        guard model.config.buddy else { return model.compactItem == .napping ? .sleepy : nil }
        switch model.compactItem {
        case .attention?: return .alert
        case .napping?: return .sleepy
        case .running?, .progress?: return .working
        case .finished(_, _, let failed)?: return failed ? .sad : .happy
        default: return nil
        }
    }

    @ViewBuilder
    private var leading: some View {
        if let mood = buddyMood {
            Buddy(mood: mood, size: model.compactBuddySize)
        } else {
            otherLeading
        }
    }

    @ViewBuilder
    private var otherLeading: some View {
        switch model.compactItem {
        case .hud(let hud)?:
            Image(systemName: hud.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 20)
        case .attention(let agent)?:
            agentIcon(agent, mood: .alert)
        case .napping?:
            Buddy(mood: .sleepy, size: model.compactBuddySize)
        case .event(let event)?, .ongoing(let event)?:
            HStack(spacing: 6) {
                Capsule().fill(event.color).frame(width: 3, height: 13)
                Text(event.title)
                    .font(Theme.Font.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        case .running(_, let agent)?:
            agentIcon(agent, mood: .working)
        case .progress(let a)?:
            agentIcon(a.agent, mood: .working)
        case .finished(_, let agent, let failed)?:
            agentIcon(agent, mood: failed ? .sad : .happy)
        case .timer(let timer)?:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                ProgressRing(progress: timer.fractionLeft(at: context.date),
                             color: timer.isPaused ? Theme.inkSecondary : Theme.accent, size: 16, lineWidth: 1.5)
                    .overlay {
                        Image(systemName: timer.isPaused ? "pause.fill" : "timer")
                            .font(.system(size: 6.5, weight: .bold))
                            .foregroundStyle(timer.isPaused ? Theme.inkSecondary : Theme.accent)
                    }
            }
            .accessibilityHidden(true)
        case .music?:
            ArtworkView(model: model, size: 20, matchID: "art")
        case .sports(let game)?:
            compactTeam(game.away)
        case .scoreAndMusic(let game, _)?:
            compactScore(game)
        case .ai(let activity, let count)?:
            HStack(spacing: 6) {
                if model.config.buddy { Buddy(mood: activity.buddyMood, size: 26, animating: activity.isLive) }
                else { AgentGlyph(agent: activity.agent, animating: activity.isLive) }
                Text(activity.agent.displayName).font(Theme.Font.headline).lineLimit(1)
                if count > 1 { Text("+\(count - 1)").font(Theme.Font.number).foregroundStyle(Theme.inkSecondary) }
            }
        case nil:
            EmptyView()
        }
    }

    /// Nori when the buddy is on; the agent's own glyph otherwise.
    @ViewBuilder
    private func agentIcon(_ agent: AgentKind, mood: BuddyMood) -> some View {
        if model.config.buddy {
            Buddy(mood: mood, size: model.compactBuddySize)
        } else {
            AgentGlyph(agent: agent, animating: mood == .working)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.compactItem {
        case .hud(let hud)?:
            LevelBar(level: hud.muted ? 0 : hud.level, tint: hud.kind == .brightness ? Palette.amber : Theme.ink)
                .frame(width: 50, height: 5)
        case .napping?:
            if let next = model.nextEventToday {
                HStack(spacing: 4) {
                    Circle().fill(next.color).frame(width: 6, height: 6)
                    Text(next.start, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                        .font(Theme.Font.number)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                        .fixedSize()
                }
                .help("Next: \(next.title)")
            }
        case .attention?:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.amber)
                .symbolEffect(.pulse, options: .repeating, isActive: !Theme.reduceMotion)
        case .ongoing(let event)?:
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let left = max(Int((event.end.timeIntervalSince(context.date) / 60).rounded(.up)), 0)
                HStack(spacing: 5) {
                    Text(left >= 60 ? "\(left / 60)h \(left % 60)m left" : "\(left) min left")
                        .font(Theme.Font.headline.monospacedDigit())
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                    ProgressRing(
                        progress: min(max(context.date.timeIntervalSince(event.start) / max(event.end.timeIntervalSince(event.start), 1), 0), 1),
                        color: event.color, size: 12, lineWidth: 2
                    )
                }
            }
        case .event(let event)?:
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let minutes = Int((event.start.timeIntervalSince(context.date) / 60).rounded(.up))
                Text(minutes <= 0 ? "Now" : "in \(minutes) min")
                    .font(Theme.Font.headline.monospacedDigit())
                    .foregroundStyle(minutes <= 5 ? Palette.amber : Theme.inkSecondary)
                    .lineLimit(1)
                    .contentTransition(.numericText(countsDown: true))
            }
        case .running(let count, let agent)?:
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(agent.tint)
                    .contentTransition(.numericText())
            } else {
                ArcSpinner(color: agent.tint, size: 13)
            }
        case .progress(let a)?:
            ProgressRing(progress: a.progress ?? 0, color: a.agent.tint, size: 15)
        case .finished(let count, _, let failed)?:
            HStack(spacing: 3) {
                Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(failed ? Palette.red : Palette.green)
                    .symbolEffect(.bounce, value: count)
                if count > 1 {
                    Text("\(count)").font(Theme.Font.number).foregroundStyle(Theme.inkSecondary)
                }
            }
        case .timer(let timer)?:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(QuickTimer.clock(timer.remaining(at: context.date)))
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(timer.isPaused ? Theme.inkSecondary : Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(timer.label), \(timer.isPaused ? "paused" : "counting down")")
            .accessibilityIdentifier("compact.timer")
        case .music(let np)?:
            EqualizerBars(playing: np.isPlaying, color: model.accent ?? np.appTint)
        case .scoreAndMusic(_, let np)?:
            HStack(spacing: 6) {
                EqualizerBars(playing: np.isPlaying, color: model.accent ?? np.appTint)
                ArtworkView(model: model, size: 20, matchID: "art")
            }
        case .sports(let game)?:
            HStack(spacing: 5) {
                if game.isLive { Circle().fill(Palette.green).frame(width: 5, height: 5) }
                compactTeam(game.home)
            }
        case .ai(let activity, _)?:
            HStack(spacing: 5) {
                if activity.isLive { ArcSpinner(color: activity.agent.tint, size: 10) }
                else if activity.state == .failed { Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.red) }
                else { Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green) }
                Text(activity.phase ?? (activity.isLive ? "Working…" : "Finished"))
                    .font(Theme.Font.number).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
        case nil:
            EmptyView()
        }
    }

    /// Both scores in one wing, so the other wing is free for music.
    private func compactScore(_ game: SportsGame) -> some View {
        HStack(spacing: 4) {
            if game.isLive { Circle().fill(Palette.green).frame(width: 5, height: 5) }
            Text(game.away.abbreviation).foregroundStyle(game.away.tint)
            Text("\(game.away.score)–\(game.home.score)").foregroundStyle(Theme.ink)
            Text(game.home.abbreviation).foregroundStyle(game.home.tint)
        }
        .font(Theme.Font.headline.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .help("\(game.matchup) · \(game.status)")
    }

    private func compactTeam(_ team: SportsTeam) -> some View {
        HStack(spacing: 5) {
            TeamLogo(team: team, size: 18)
            Text(team.abbreviation).foregroundStyle(team.tint)
            Text(team.score).foregroundStyle(Theme.ink)
        }
        .font(Theme.Font.headline.monospacedDigit())
        .lineLimit(1)
    }
}
