import AppKit
import SwiftUI

/// Cove's design tokens. The island is pure black and shaped like the iPhone's Dynamic Island;
/// everything on it is built from a few white tints, one type family (SF Pro, rounded for titles
/// and numbers), and concentric corner radii.
enum Theme {
    /// The look in use. Set from the config on the main thread; views re-render when the config changes.
    static var style: IslandTheme = .darkMatte
    static var isTerminal: Bool { style == .terminal }

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
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A quick, well-damped spring keeps the panel anchored without overshoot.
    static var morph: Animation {
        reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.34, dampingFraction: 0.90, blendDuration: 0.1)
    }

    /// Small state changes inside the island.
    static var snappy: Animation {
        reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.25, dampingFraction: 0.92)
    }
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

// MARK: - Morph transition

/// Content fades while the shell moves; text and controls keep their scale.
extension AnyTransition {
    static var islandMorph: AnyTransition {
        .opacity.animation(.easeOut(duration: Theme.reduceMotion ? 0.10 : 0.16))
    }
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
