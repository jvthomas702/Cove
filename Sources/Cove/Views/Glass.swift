import AppKit
import SwiftUI

// Liquid glass for the island. The island is black, so there's nothing behind it to refract:
// the glass is built from what's playing instead. The album art, blurred and saturated, sits
// under a frosted layer with a specular sheen and a rim that catches the light at the top-left,
// and two soft blobs of the art's color drift underneath while music plays. On macOS 26 built
// with Xcode 26, buttons use the system's own Liquid Glass.

extension Theme {
    /// The rim of a glass surface: bright where the light hits (top-left), almost gone below.
    static var glassRim: LinearGradient {
        LinearGradient(stops: [.init(color: .white.opacity(0.42), location: 0),
                               .init(color: .white.opacity(0.08), location: 0.45),
                               .init(color: .white.opacity(0.16), location: 1)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The sheen across the top of a glass surface.
    static var glassSheen: LinearGradient {
        LinearGradient(stops: [.init(color: .white.opacity(0.16), location: 0),
                               .init(color: .white.opacity(0.03), location: 0.42),
                               .init(color: .clear, location: 0.6)],
                       startPoint: .top, endPoint: .bottom)
    }
}

/// A liquid-glass panel tinted by album art (or by `tint` when there's no art).
struct LiquidGlassBackground: View {
    var artwork: NSImage?
    var tint: Color
    var cornerRadius: CGFloat = 18
    /// Drift the color underneath (while music plays).
    var flowing = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        // One Canvas draws the art and the moving color, so nothing inside the panel can reach past the
        // tile: no child view is larger than it, for drawing, clicks or accessibility frames alike.
        Color.black
            .overlay { LiquidLayer(artwork: artwork, tint: tint, flowing: flowing && !Theme.reduceMotion) }
            // Frost, sheen, and a darker floor so white text stays readable on bright art.
            .overlay { Color.white.opacity(0.035) }
            .overlay { Theme.glassSheen }
            .overlay { LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .center, endPoint: .bottom) }
            .clipShape(shape)
            .overlay { shape.strokeBorder(Theme.glassRim, lineWidth: 1) }
            .overlay { shape.inset(by: 1.5).strokeBorder(Color.white.opacity(0.05), lineWidth: 0.5) }
            .shadow(color: tint.opacity(0.22), radius: 16, y: 8)
            .animation(.easeInOut(duration: 0.8), value: artwork == nil)
            // Purely decoration: clicks go to the controls on top, never to the glass.
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The album art, blurred and saturated to fill the panel, with two soft blobs of its color wandering
/// slowly over it like light moving through liquid. Drawn in one Canvas, clipped to its own frame.
private struct LiquidLayer: View {
    var artwork: NSImage?
    var tint: Color
    var flowing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24, paused: !flowing)) { timeline in
            let t = flowing ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                let w = size.width, h = size.height
                if let artwork, artwork.size.width > 0, artwork.size.height > 0 {
                    var art = context
                    art.opacity = 0.62
                    art.addFilter(.saturation(1.5))
                    art.addFilter(.blur(radius: 26))
                    let scale = max(w / artwork.size.width, h / artwork.size.height) * 1.6
                    let drawn = CGSize(width: artwork.size.width * scale, height: artwork.size.height * scale)
                    art.draw(Image(nsImage: artwork),
                             in: CGRect(x: (w - drawn.width) / 2, y: (h - drawn.height) / 2, width: drawn.width, height: drawn.height))
                }
                var blobs = context
                blobs.opacity = artwork == nil ? 0.55 : 0.35
                blobs.addFilter(.blur(radius: 30))
                let first = w * 0.8, second = w * 0.6
                blobs.fill(Path(ellipseIn: CGRect(x: w * (0.25 + 0.12 * sin(t * 0.35)) - first / 2,
                                                  y: h * (0.3 + 0.15 * cos(t * 0.27)) - first / 2,
                                                  width: first, height: first)),
                           with: .color(tint))
                blobs.fill(Path(ellipseIn: CGRect(x: w * (0.8 + 0.1 * cos(t * 0.31)) - second / 2,
                                                  y: h * (0.75 + 0.12 * sin(t * 0.4)) - second / 2,
                                                  width: second, height: second)),
                           with: .color(tint.opacity(0.7)))
            }
        }
    }
}

/// A round glass control. `prominent` is the solid white one in the middle (play / pause).
struct GlassIconButton: View {
    var systemImage: String
    var size: CGFloat = 12
    var diameter: CGFloat = 26
    var prominent = false
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size, weight: .bold))
                .foregroundStyle(prominent ? Color.black : Color.white.opacity(0.92))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: diameter, height: diameter)
                .background { GlassCircle(prominent: prominent, hovering: hovering && enabled) }
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .opacity(enabled ? 1 : 0.4)
        .onHover { hovering = $0 }
        .animation(Theme.snappy, value: hovering)
    }
}

private struct GlassCircle: View {
    var prominent: Bool
    var hovering: Bool

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            SystemGlassCircle(prominent: prominent)
        } else {
            drawn
        }
        #else
        drawn
        #endif
    }

    private var drawn: some View {
        ZStack {
            if prominent {
                Circle().fill(Color.white.opacity(hovering ? 1 : 0.92))
                Circle().fill(LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .top, endPoint: .center)).opacity(0.5)
            } else {
                Circle().fill(Color.white.opacity(hovering ? 0.16 : 0.08))
                Circle().fill(Theme.glassSheen)
                Circle().strokeBorder(Theme.glassRim, lineWidth: 0.75)
            }
        }
        .shadow(color: .black.opacity(prominent ? 0.35 : 0.2), radius: prominent ? 6 : 3, y: 2)
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
private struct SystemGlassCircle: View {
    var prominent: Bool

    var body: some View {
        Color.clear.glassEffect(prominent ? .regular.tint(.white).interactive() : .regular.interactive(), in: Circle())
    }
}
#endif
