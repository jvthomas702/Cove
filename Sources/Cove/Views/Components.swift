import AppKit
import QuickLookThumbnailing
import SwiftUI

// MARK: - Agent & status glyphs

/// Agent icon (Claude sparkle, Codex brackets, terminal…), breathing while the agent works.
struct AgentGlyph: View {
    var agent: AgentKind
    var animating = false
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: agent.symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(agent.tint)
            .symbolEffect(.pulse, options: .repeating, isActive: animating && !Theme.reduceMotion)
    }
}

/// Agent glyph on a soft tinted tile — used in lists and the approval header.
struct AgentTile: View {
    var agent: AgentKind
    var animating = false
    var size: CGFloat = 28

    var body: some View {
        AgentGlyph(agent: agent, animating: animating, size: size * 0.46)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .fill(agent.tint.opacity(0.16))
            )
    }
}

/// Lightweight spinner (cheaper than ProgressView and right on black).
struct ArcSpinner: View {
    var color: Color = .white
    var size: CGFloat = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: Theme.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(
                    AngularGradient(colors: [color.opacity(0), color], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(260)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round)
                )
                .rotationEffect(.degrees((t * 330).truncatingRemainder(dividingBy: 360)))
                .frame(width: size, height: size)
        }
    }
}

struct ProgressRing: View {
    var progress: Double
    var color: Color
    var size: CGFloat = 14
    var lineWidth: CGFloat = 2.5

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
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
        TimelineView(.animation(minimumInterval: 1.0 / 15, paused: !playing || Theme.reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2.5) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = Double(i)
                    let wave = abs(sin(t * (3.8 + phase * 1.35) + phase * 1.7)) * 0.7 + abs(sin(t * 1.9 + phase)) * 0.3
                    let height = playing ? 4 + 11 * wave : 4
                    Capsule()
                        .fill(color)
                        .frame(width: 2.5, height: height)
                }
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Media

/// Album art from the model (Music bytes or a Spotify download), with a quiet placeholder.
struct ArtworkView: View {
    @ObservedObject var model: IslandModel
    var size: CGFloat
    var matchID: String? = nil
    @Environment(\.islandNamespace) private var namespace

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: max(5, size * 0.24), style: .continuous)
        Group {
            if let image = model.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [tint.opacity(0.85), tint.opacity(0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.42, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
        .islandMatched(matchID ?? "artwork", in: matchID == nil ? nil : namespace)
    }

    private var tint: Color { model.accent ?? model.nowPlaying?.appTint ?? Palette.music }
}

/// Thin playback progress with elapsed / remaining time.
struct PlaybackBar: View {
    let nowPlaying: NowPlaying
    var tint: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let elapsed = nowPlaying.elapsed(at: context.date) ?? 0
            let duration = nowPlaying.duration ?? 0
            VStack(spacing: 3) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surfaceRaised)
                        Capsule()
                            .fill(tint)
                            .frame(width: duration > 0 ? geo.size.width * min(elapsed / duration, 1) : 0)
                    }
                }
                .frame(height: 3)
                HStack {
                    Text(Self.clock(elapsed))
                    Spacer()
                    Text("-" + Self.clock(max(duration - elapsed, 0)))
                }
                .font(.system(size: 9.5, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.inkTertiary)
            }
            .opacity(duration > 0 ? 1 : 0)
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Picks a vivid color from album art, the way the iPhone tints Now Playing.
enum ArtworkTint {
    static func color(from image: NSImage) -> Color? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 12
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }

        // Weight each pixel by how vivid it is, so a colorful subject beats a grey background.
        var r = 0.0, g = 0.0, b = 0.0, total = 0.0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let pr = Double(pixels[i]) / 255, pg = Double(pixels[i + 1]) / 255, pb = Double(pixels[i + 2]) / 255
            let high = max(pr, pg, pb), low = min(pr, pg, pb)
            let saturation = high == 0 ? 0 : (high - low) / high
            let weight = 0.05 + saturation * high * high
            r += pr * weight; g += pg * weight; b += pb * weight; total += weight
        }
        guard total > 0 else { return nil }
        let average = NSColor(srgbRed: r / total, green: g / total, blue: b / total, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        // Near-grey art: use a soft white instead of inventing a color.
        if saturation < 0.12 { return Color(white: 0.86) }
        // Keep it readable on black: bright enough, not neon.
        return Color(hue: hue, saturation: min(max(saturation, 0.4), 0.8), brightness: max(brightness, 0.82))
    }
}

// MARK: - Banners, files, levels

struct BannerIconView: View {
    var icon: BannerIcon
    var size: CGFloat = 34

    var body: some View {
        switch icon {
        case .symbol(let name, let color):
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(color.opacity(0.18))
                Image(systemName: name)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(color)
            }
            .frame(width: size, height: size)
        case .buddy(let mood, let agent):
            Buddy(mood: mood, size: size * 1.1, badge: agent)
                .frame(width: size, height: size)
        case .file(let url):
            FileThumbnail(url: url, size: size)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous))
        case .app(let bundleID):
            if let image = AppIcons.icon(for: bundleID) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.3, style: .continuous).fill(Palette.blue.opacity(0.18))
                    Image(systemName: "app.badge.fill").foregroundStyle(Palette.blue)
                }
                .frame(width: size, height: size)
            }
        }
    }
}

/// Quick Look thumbnail for a file (falls back to its Finder icon while loading).
struct FileThumbnail: View {
    let url: URL
    var size: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(
                fileAt: url,
                size: CGSize(width: size * 2, height: size * 2),
                scale: NSScreen.main?.backingScaleFactor ?? 2,
                representationTypes: .thumbnail
            )
            if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                image = representation.nsImage
            }
        }
    }
}

/// Horizontal level meter for the volume / brightness HUD.
struct LevelBar: View {
    var level: Double
    var tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(tint)
                    .frame(width: max(geo.size.height, geo.size.width * min(max(level, 0), 1)))
                    .opacity(level <= 0.001 ? 0 : 1)
            }
        }
        .animation(Theme.snappy, value: level)
    }
}

/// A drawn battery (outline, fill, nub) — crisper than the SF Symbol at this size and shows the exact level.
struct BatteryGlyph: View {
    let state: BatteryState

    var body: some View {
        HStack(spacing: 5) {
            Text("\(state.percent)%")
                .font(Theme.Font.number)
                .foregroundStyle(Theme.inkSecondary)
            HStack(spacing: 1) {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(fill)
                        .frame(width: max(2, 18 * CGFloat(state.percent) / 100))
                        .padding(2)
                    if state.pluggedIn {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 7, weight: .black))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.6), radius: 1)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: 24, height: 12)
                RoundedRectangle(cornerRadius: 1).fill(Color.white.opacity(0.45)).frame(width: 1.5, height: 4)
            }
        }
    }

    private var fill: Color {
        if state.pluggedIn { return Palette.green }
        if state.percent <= 20 { return Palette.red }
        return Color.white.opacity(0.9)
    }
}

// MARK: - Buttons

/// Rounded chip button used for small actions (timer presets, Join, Clear).
struct ChipButton: View {
    var title: String
    var systemImage: String? = nil
    var tint: Color = Theme.ink
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .bold)) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Capsule().fill(hovering ? Color.white.opacity(0.17) : Theme.surfaceRaised))
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

struct IconButton: View {
    var systemImage: String
    var size: CGFloat = 14
    /// Size of the round hit area (defaults to the glyph plus padding).
    var hit: CGFloat? = nil
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .semibold))
                .frame(width: hit ?? size + 16, height: hit ?? size + 16)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
    }
}

/// Buttons dip slightly when pressed, so clicks feel physical.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
