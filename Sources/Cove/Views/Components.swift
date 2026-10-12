import AppKit
import SwiftUI

/// Agent icon (Claude sparkle, Codex brackets, terminal…), pulsing while the agent works.
struct AgentGlyph: View {
    var agent: AgentKind
    var animating = false
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: agent.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(agent.tint)
            .symbolEffect(.pulse, isActive: animating)
    }
}

/// Lightweight spinner (cheaper than ProgressView and looks right on black).
struct ArcSpinner: View {
    var color: Color = .white
    var size: CGFloat = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees((t * 360).truncatingRemainder(dividingBy: 360)))
                .frame(width: size, height: size)
        }
    }
}

struct ProgressRing: View {
    var progress: Double
    var color: Color
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.25), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .animation(.easeOut(duration: 0.3), value: progress)
    }
}

/// Animated music bars for the compact Now Playing state.
struct EqualizerBars: View {
    var playing: Bool
    var color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !playing)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = Double(i)
                    let height = playing ? 4 + 10 * abs(sin(t * (4.5 + phase * 1.6) + phase)) : 4
                    Capsule()
                        .fill(color)
                        .frame(width: 3, height: height)
                }
            }
            .frame(height: 16)
        }
    }
}

struct ArtworkView: View {
    var nowPlaying: NowPlaying
    var size: CGFloat

    var body: some View {
        Group {
            if let url = nowPlaying.artworkURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(colors: [nowPlaying.tint.opacity(0.9), nowPlaying.tint.opacity(0.4)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
    }
}

struct BannerIconView: View {
    var icon: BannerIcon

    var body: some View {
        switch icon {
        case .symbol(let name, let color):
            ZStack {
                Circle().fill(color.opacity(0.18))
                Image(systemName: name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
            }
        case .app(let bundleID):
            if let image = AppIcons.icon(for: bundleID) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    Circle().fill(Palette.blue.opacity(0.18))
                    Image(systemName: "app.badge.fill").foregroundStyle(Palette.blue)
                }
            }
        }
    }
}

/// Small rounded "chip" button used across the expanded view.
struct ChipButton: View {
    var title: String
    var systemImage: String? = nil
    var tint: Color = .white
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.16 : 0.09)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct IconButton: View {
    var systemImage: String
    var size: CGFloat = 14
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(width: size + 14, height: size + 14)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.14 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
