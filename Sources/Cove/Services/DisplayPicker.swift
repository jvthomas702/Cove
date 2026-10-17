import CoreGraphics

/// Which display the island lives on (Settings → General → Show on).
enum IslandDisplay: String, Codable, CaseIterable {
    /// The MacBook's notch; the main display when the lid is closed or there is no notch.
    case notch
    /// Whichever display the pointer is on, following it from screen to screen.
    case active

    var title: String {
        switch self {
        case .notch: return "Notch display"
        case .active: return "Active display"
        }
    }
}

/// What the picker needs to know about a screen, so the choice can be tested without real displays.
struct ScreenDescriptor: Equatable {
    var frame: CGRect
    var hasNotch: Bool
    /// `NSScreen.main`: the screen holding the window with keyboard focus.
    var isMain: Bool
}

enum DisplayPicker {
    /// Index into `screens` of the display the island should be on, or nil when there are none.
    static func pick(_ screens: [ScreenDescriptor], mode: IslandDisplay, mouse: CGPoint?) -> Int? {
        guard !screens.isEmpty else { return nil }
        let main = screens.firstIndex(where: \.isMain)
        switch mode {
        case .notch:
            return screens.firstIndex(where: \.hasNotch) ?? main ?? 0
        case .active:
            if let mouse, let under = screens.firstIndex(where: { contains($0.frame, mouse) }) { return under }
            return main ?? screens.firstIndex(where: \.hasNotch) ?? 0
        }
    }

    /// The pointer can sit exactly on a screen's top edge (y == maxY), so the top is inclusive.
    /// The right edge is exclusive so side-by-side displays don't both claim their shared border.
    static func contains(_ frame: CGRect, _ point: CGPoint) -> Bool {
        point.x >= frame.minX && point.x < frame.maxX && point.y >= frame.minY && point.y <= frame.maxY
    }
}
