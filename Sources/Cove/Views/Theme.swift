import AppKit
import SwiftUI

/// Cove's design tokens. The island is pure black and shaped like the iPhone's Dynamic Island;
/// everything on it is built from a few white tints, one type family (SF Pro, rounded for titles
/// and numbers), and concentric corner radii.
enum Theme {
    /// The look in use. Set from the config on the main thread; views re-render when the config changes.
    static var style: IslandTheme = .darkMatte
    static var isTerminal: Bool { style == .terminal }
    static var buttonLook: ButtonLook = .outline

    // MARK: Ink (text and icons on black)
    static var ink: Color { isTerminal ? Color(hex: 0xA6F5B8) : Color(hex: 0xE3E7EF) }
    static var inkSecondary: Color { isTerminal ? Color(hex: 0x5FB574) : Color(hex: 0xA4ABBA) }
    static var inkTertiary: Color { inkSecondary.opacity(0.72) }

    // MARK: Surfaces (layered on the black island)
    static let background = Color(hex: 0x000000)
    static var surface: Color { isTerminal ? Color(hex: 0x050D07) : Color(hex: 0x111216) }
    static var surfaceRaised: Color { isTerminal ? Color(hex: 0x0C1C10) : Color(hex: 0x222329) }
    static var hairline: Color { isTerminal ? Color(hex: 0x3BE36A).opacity(0.22) : Color(hex: 0xE3E7EF).opacity(0.10) }
    static var accent: Color { isTerminal ? Color(hex: 0x3BE36A) : Color(hex: 0x8FC7FF) }

    // MARK: Spacing (4-pt grid)
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    // MARK: Radii — concentric: island 34 → card (34 − 14 inset) 20 → row 12.
    // The banner is near-pill, like an iPhone live activity dropping out of the island.
    // The terminal look squares everything off.
    enum Radius {
        static let islandExpanded: CGFloat = 34
        static let islandBanner: CGFloat = 30
        static var card: CGFloat { Theme.isTerminal ? 6 : 20 }
        static var row: CGFloat { Theme.isTerminal ? 4 : 12 }
        static var thumb: CGFloat { Theme.isTerminal ? 3 : 8 }
    }

    // MARK: Type (all monospaced in the terminal look)
    enum Font {
        private static var rounded: SwiftUI.Font.Design { Theme.isTerminal ? .monospaced : .rounded }
        private static var plain: SwiftUI.Font.Design { Theme.isTerminal ? .monospaced : .default }
        static var title: SwiftUI.Font { .system(size: 13, weight: .semibold, design: rounded) }
        static var headline: SwiftUI.Font { .system(size: 12, weight: .semibold, design: rounded) }
        static var body: SwiftUI.Font { .system(size: 11, design: plain) }
        static var caption: SwiftUI.Font { .system(size: 10, design: plain) }
        static var section: SwiftUI.Font { .system(size: 11, weight: .semibold, design: rounded) }
        static var number: SwiftUI.Font { .system(size: 10, weight: .semibold, design: rounded).monospacedDigit() }
        static let code = SwiftUI.Font.system(size: 10, design: .monospaced)
    }

    // MARK: Motion
    //
    // Springs, never curves, the way the iPhone's Dynamic Island moves: the shell stretches with a
    // little overshoot, content resolves out of a blur, and lists build in one row after another
    // (each row its own spring, offset by a few frames, like a Remotion sequence). Reduce Motion
    // turns all of it into short cross-fades.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// The island changing shape: elastic, settles in about half a second.
    static var morph: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(duration: 0.5, bounce: 0.2)
    }

    /// Small state changes inside the island (a pill sliding, a row highlighting).
    static var snappy: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.12)
    }

    /// Content arriving: no overshoot, so text never wobbles.
    static var settle: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.45, bounce: 0)
    }

    /// Buttons dipping under a click and springing back.
    static var press: Animation {
        reduceMotion ? .easeOut(duration: 0.05) : .spring(duration: 0.22, bounce: 0.35)
    }

    /// How far apart rows start when a list builds in: two frames at 60 fps, capped so long lists stay quick.
    static func stagger(_ index: Int) -> Double { reduceMotion ? 0 : Double(min(max(index, 0), 12)) * 0.035 }
}

extension IslandTheme {
    var colorScheme: ColorScheme { .dark }
}

/// Trackpad haptic tap (only felt on Force Touch trackpads while a finger is resting on them).
enum Haptics {
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    static func notice() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

// MARK: - Transitions

/// Blur, scale and fade together: content looks like it comes into focus rather than popping in.
private struct Materialize: ViewModifier {
    var progress: Double   // 0 = hidden, 1 = shown
    var scale: CGFloat
    var blur: CGFloat
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(1 - (1 - scale) * (1 - progress), anchor: anchor)
            .blur(radius: blur * (1 - progress))
    }
}

/// Slides in from the side you're heading to, the way pages move in Apple's segmented views.
private struct Slide: ViewModifier {
    var progress: Double
    var dx: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .offset(x: dx * (1 - progress))
            .blur(radius: 6 * (1 - progress))
    }
}

extension AnyTransition {
    /// The island's content while the shell changes shape: it resolves out of a blur from the notch
    /// a beat after the shell starts moving, and blurs away quickly when the shell closes.
    static var islandMorph: AnyTransition {
        if Theme.reduceMotion { return .opacity.animation(.easeOut(duration: 0.10)) }
        return .asymmetric(
            insertion: .modifier(active: Materialize(progress: 0, scale: 0.92, blur: 10, anchor: .top),
                                 identity: Materialize(progress: 1, scale: 0.92, blur: 10, anchor: .top))
                .animation(.spring(duration: 0.42, bounce: 0).delay(0.06)),
            removal: .modifier(active: Materialize(progress: 0, scale: 0.96, blur: 6, anchor: .top),
                               identity: Materialize(progress: 1, scale: 0.96, blur: 6, anchor: .top))
                .animation(.easeOut(duration: 0.12))
        )
    }

    /// One thing swapping for another in place (a wing's icon, a status line).
    static var materialize: AnyTransition {
        if Theme.reduceMotion { return .opacity }
        return .modifier(active: Materialize(progress: 0, scale: 0.8, blur: 4, anchor: .center),
                         identity: Materialize(progress: 1, scale: 0.8, blur: 4, anchor: .center))
    }

    /// A tab's content arriving from the direction of the tab you picked.
    static func tabSlide(forward: Bool) -> AnyTransition {
        if Theme.reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: Slide(progress: 0, dx: forward ? 28 : -28), identity: Slide(progress: 1, dx: forward ? 28 : -28)),
            removal: .modifier(active: Materialize(progress: 0, scale: 0.98, blur: 6, anchor: .center),
                               identity: Materialize(progress: 1, scale: 0.98, blur: 6, anchor: .center))
                .animation(.easeOut(duration: 0.12))
        )
    }
}

/// Builds a row in on first appearance: up from a few points below, out of a blur, on its own
/// spring that starts `Theme.stagger(index)` after the first row's.
private struct Entrance: ViewModifier {
    let index: Int
    @State private var shown = Theme.reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 10)
            .scaleEffect(shown ? 1 : 0.97, anchor: .top)
            .blur(radius: shown ? 0 : 5)
            .onAppear {
                guard !shown else { return }
                withAnimation(Theme.settle.delay(Theme.stagger(index))) { shown = true }
            }
    }
}

extension View {
    /// Staggered entrance for the `index`th row of a list or grid (see `Entrance`).
    func entrance(_ index: Int) -> some View { modifier(Entrance(index: index)) }
}

// MARK: - Shared building blocks

/// A surface card with the concentric card radius.
struct CardBackground: ViewModifier {
    var fill: Color = Theme.surface

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(fill)
        )
    }
}

extension View {
    func card(_ fill: Color = Theme.surface) -> some View { modifier(CardBackground(fill: fill)) }
}

/// Sentence-case section heading with an optional quiet count.
struct SectionTitle: View {
    let title: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(Theme.Font.section).foregroundStyle(Theme.inkSecondary)
            if let count, count > 0 {
                Text("\(count)").font(Theme.Font.number).foregroundStyle(Theme.inkTertiary)
            }
        }
    }
}
