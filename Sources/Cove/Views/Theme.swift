import AppKit
import SwiftUI

/// Matte surfaces use the selected appearance. Closed states keep the real notch black.
enum Theme {
    // MARK: Ink (text and icons on black)
    static let ink = adaptive(light: 0x1E2129, dark: 0xE3E7EF)
    static let inkSecondary = adaptive(light: 0x545A69, dark: 0xA4ABBA)
    static let inkTertiary = inkSecondary.opacity(0.72)

    // MARK: Surfaces (layered on the black island)
    static let background = adaptive(light: 0xF7F8FA, dark: 0x000000)
    static let surface = adaptive(light: 0xFBFBFC, dark: 0x111216)
    static let surfaceRaised = adaptive(light: 0xE8EBEF, dark: 0x222329)
    static let hairline = adaptive(light: 0x1E2129, dark: 0xE3E7EF).opacity(0.10)
    static let accent = adaptive(light: 0x3B82D0, dark: 0x8FC7FF)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255,
                           green: CGFloat((hex >> 8) & 255) / 255,
                           blue: CGFloat(hex & 255) / 255, alpha: 1)
        })
    }

    // MARK: Spacing (4-pt grid)
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
    }

    // MARK: Radii — concentric: island 34 → card (34 − 14 inset) 20 → row 12
    enum Radius {
        static let islandExpanded: CGFloat = 42
        static let islandBanner: CGFloat = 26
        static let card: CGFloat = 20
        static let row: CGFloat = 12
        static let thumb: CGFloat = 8
    }

    // MARK: Type
    enum Font {
        static let title = SwiftUI.Font.system(size: 14, weight: .semibold, design: .rounded)
        static let headline = SwiftUI.Font.system(size: 13, weight: .semibold, design: .rounded)
        static let body = SwiftUI.Font.system(size: 12)
        static let caption = SwiftUI.Font.system(size: 11)
        static let section = SwiftUI.Font.system(size: 12, weight: .semibold, design: .rounded)
        static let number = SwiftUI.Font.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit()
        static let code = SwiftUI.Font.system(size: 11, design: .monospaced)
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
    var colorScheme: ColorScheme { self == .whiteMatte ? .light : .dark }
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
