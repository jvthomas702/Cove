import SwiftUI

/// Live-activity state: content sits in the two "wings" either side of the physical notch,
/// like the iPhone's compact leading/trailing views.
struct CompactView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let wing = IslandModel.wing - IslandModel.ear
        HStack(spacing: 0) {
            leading.frame(width: wing)
            Color.clear.frame(width: model.notchSize.width)
            trailing.frame(width: wing)
        }
        .frame(height: model.notchSize.height)
        .contentShape(Rectangle())
        .onTapGesture { model.setExpanded(true) }
    }

    @ViewBuilder
    private var leading: some View {
        switch model.compactItem {
        case .attention(let agent)?:
            AgentGlyph(agent: agent)
        case .running(_, let agent)?:
            AgentGlyph(agent: agent, animating: true)
        case .progress(let a)?:
            AgentGlyph(agent: a.agent, animating: true)
        case .finished(_, let agent, _)?:
            AgentGlyph(agent: agent)
        case .focus?:
            Image(systemName: "timer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.amber)
        case .music(let np)?:
            ArtworkView(nowPlaying: np, size: 20)
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.compactItem {
        case .attention?:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Palette.amber)
                .symbolEffect(.pulse, isActive: true)
        case .running(let count, let agent)?:
            if count > 1 {
                Text("\(count)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(agent.tint)
            } else {
                ArcSpinner(color: agent.tint, size: 12)
            }
        case .progress(let a)?:
            ProgressRing(progress: a.progress ?? 0, color: a.agent.tint)
        case .finished(let count, _, let failed)?:
            HStack(spacing: 2) {
                Image(systemName: failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(failed ? Palette.red : Palette.green)
                if count > 1 {
                    Text("\(count)").font(.system(size: 11, weight: .bold, design: .rounded))
                }
            }
        case .focus(let end)?:
            Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Palette.amber)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        case .music(let np)?:
            EqualizerBars(playing: np.isPlaying, color: np.tint)
        case nil:
            EmptyView()
        }
    }
}
