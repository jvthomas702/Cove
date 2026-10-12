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
        .onTapGesture { model.setExpanded(true) }
        .animation(Theme.snappy, value: model.compactItem)
    }

    private var isWide: Bool { model.compactWing > IslandModel.wing }

    @ViewBuilder
    private var leading: some View {
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
            Buddy(mood: .sleepy, size: 24)
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
        case .focus?:
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.amber)
        case .music?:
            ArtworkView(model: model, size: 20, matchID: "art")
        case nil:
            EmptyView()
        }
    }

    /// Pip when the avatar is on; the agent's own glyph otherwise.
    @ViewBuilder
    private func agentIcon(_ agent: AgentKind, mood: BuddyMood) -> some View {
        if model.config.buddy {
            Buddy(mood: mood, size: 24)
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
            EmptyView()
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
        case .focus(let end)?:
            Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                .font(Theme.Font.number)
                .foregroundStyle(Palette.amber)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        case .music(let np)?:
            EqualizerBars(playing: np.isPlaying, color: model.accent ?? np.appTint)
        case nil:
            EmptyView()
        }
    }
}
