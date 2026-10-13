import SwiftUI

/// Pip — Cove's little avatar. A soft aqua blob with an antenna whose bulb shows the status color.
/// Drawn entirely with SwiftUI shapes, so it stays crisp from 18 pt (beside the notch) to 40 pt (banners).
struct Buddy: View {
    var mood: BuddyMood
    var size: CGFloat = 22
    /// Small agent badge (Claude sparkle, terminal…) shown at larger sizes.
    var badge: AgentKind? = nil

    var body: some View {
        // Napping Pip is on screen all day, so it breathes at a low frame rate to save battery.
        TimelineView(.animation(minimumInterval: mood == .sleepy ? 1.0 / 6 : 1.0 / 30, paused: Theme.reduceMotion)) { context in
            BuddyFigure(mood: mood, size: size, t: Theme.reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let badge, size >= 28 {
                Image(systemName: badge.symbol)
                    .font(.system(size: size * 0.2, weight: .bold))
                    .foregroundStyle(badge.tint)
                    .frame(width: size * 0.36, height: size * 0.36)
                    .background(Circle().fill(Color.black))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 0.5))
                    .offset(x: size * 0.06, y: size * 0.04)
            }
        }
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch mood {
        case .working: return "Working"
        case .happy: return "Done"
        case .alert: return "Needs you"
        case .sad: return "Failed"
        case .sleepy: return "Idle"
        }
    }
}

/// One frame of Pip at time `t`.
private struct BuddyFigure: View {
    let mood: BuddyMood
    let size: CGFloat
    let t: Double

    private static let sparkleX: [CGFloat] = [-0.42, 0.44, -0.36]
    private static let sparkleY: [CGFloat] = [-0.26, -0.12, 0.3]

    // Pip's colors: cove water, with a status bulb.
    private let top = Color(hex: 0x9BEAF2)
    private let bottom = Color(hex: 0x4F7EF2)
    private let ink = Color(hex: 0x0D1530)
    private let cheek = Color(hex: 0xFF8FB1)

    /// Beside the notch Pip is ~30 pt, so features get bolder and fine details are dropped.
    private var small: Bool { size < 36 }

    var body: some View {
        let m = motion
        ZStack {
            // Antenna + status bulb
            VStack(spacing: 0) {
                Circle()
                    .fill(bulbColor)
                    .frame(width: size * (small ? 0.19 : 0.15), height: size * (small ? 0.19 : 0.15))
                    .shadow(color: bulbColor.opacity(0.9), radius: size * 0.08 * bulbGlow)
                    .opacity(0.65 + 0.35 * bulbGlow)
                Capsule()
                    .fill(top)
                    .frame(width: max(1, size * 0.05), height: size * 0.1)
            }
            .rotationEffect(.degrees(m.antennaTilt), anchor: .bottom)
            .offset(y: -size * 0.36)

            // Body
            RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom))
                .frame(width: size * 0.84, height: size * 0.68)
                .overlay(alignment: .topLeading) {
                    // Glossy highlight
                    Ellipse()
                        .fill(Color.white.opacity(0.45))
                        .frame(width: size * 0.2, height: size * 0.1)
                        .rotationEffect(.degrees(-20))
                        .offset(x: size * 0.1, y: size * 0.07)
                }
                .overlay { face.scaleEffect(small ? 1.2 : 1) }
                .overlay {
                    if small {
                        // A thin light rim so Pip reads against a black island.
                        RoundedRectangle(cornerRadius: size * 0.34, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 0.75)
                    }
                }
                .offset(y: size * 0.1)

            accessories
        }
        .frame(width: size, height: size)
        .scaleEffect(x: 1 + m.squash, y: 1 - m.squash, anchor: .bottom)
        .rotationEffect(.degrees(m.tilt))
        .offset(x: m.dx, y: m.dy)
    }

    // MARK: Face

    @ViewBuilder
    private var face: some View {
        let eyeSpacing = size * 0.22
        ZStack {
            HStack(spacing: eyeSpacing) {
                eye
                eye
            }
            .offset(x: lookX, y: -size * 0.04)

            // Cheeks (too fine to see at notch size)
            if !small {
                HStack(spacing: size * 0.38) {
                    Ellipse().fill(cheek.opacity(mood == .happy ? 0.75 : 0.4))
                    Ellipse().fill(cheek.opacity(mood == .happy ? 0.75 : 0.4))
                }
                .frame(width: size * 0.62, height: size * 0.06)
                .offset(y: size * 0.08)
            }

            mouth.offset(y: size * 0.12)
        }
    }

    @ViewBuilder
    private var eye: some View {
        switch mood {
        case .happy:
            // ^ ^
            ArcShape(up: true)
                .stroke(ink, style: StrokeStyle(lineWidth: max(1.2, size * 0.055), lineCap: .round))
                .frame(width: size * 0.12, height: size * 0.07)
        case .sleepy:
            Capsule().fill(ink).frame(width: size * 0.12, height: max(1.2, size * 0.04))
        case .alert:
            ZStack(alignment: .topTrailing) {
                Ellipse().fill(ink).frame(width: size * 0.13, height: size * 0.16)
                Circle().fill(Color.white).frame(width: size * 0.05, height: size * 0.05).offset(x: -size * 0.015, y: size * 0.02)
            }
        case .sad:
            Ellipse().fill(ink)
                .frame(width: size * 0.1, height: size * 0.12 * blink)
                .offset(y: size * 0.02)
        case .working:
            Ellipse().fill(ink).frame(width: size * 0.1, height: size * 0.13 * blink)
        }
    }

    @ViewBuilder
    private var mouth: some View {
        switch mood {
        case .happy:
            HalfDisc()
                .fill(ink)
                .frame(width: size * 0.16, height: size * 0.08)
        case .alert:
            Ellipse().fill(ink).frame(width: size * 0.07, height: size * 0.08)
        case .sad:
            ArcShape(up: true)
                .stroke(ink, style: StrokeStyle(lineWidth: max(1, size * 0.045), lineCap: .round))
                .frame(width: size * 0.12, height: size * 0.04)
        case .working:
            // Concentrating: a tiny line that wiggles
            Capsule().fill(ink)
                .frame(width: size * CGFloat(0.08 + 0.02 * sin(t * 3)), height: max(1, size * 0.035))
        case .sleepy:
            Circle().fill(ink.opacity(0.8)).frame(width: size * 0.05, height: size * 0.05)
        }
    }

    // MARK: Accessories

    @ViewBuilder
    private var accessories: some View {
        switch mood {
        case .happy:
            ForEach(0..<3, id: \.self) { i in
                let phase = t * 2.4 + Double(i) * 2.1
                Sparkle()
                    .fill(i == 1 ? Palette.amber : Color.white)
                    .frame(width: size * 0.16, height: size * 0.16)
                    .scaleEffect(CGFloat(0.4 + 0.6 * abs(sin(phase))))
                    .opacity(0.3 + 0.7 * abs(sin(phase)))
                    .offset(x: Self.sparkleX[i] * size, y: Self.sparkleY[i] * size)
            }
        case .alert:
            Text("!")
                .font(.system(size: size * 0.32, weight: .black, design: .rounded))
                .foregroundStyle(Palette.amber)
                .offset(x: size * 0.42, y: -size * 0.3 + CGFloat(sin(t * 8)) * size * 0.03)
        case .sad:
            // A tear sliding down
            let drop = (t * 0.7).truncatingRemainder(dividingBy: 1)
            Teardrop()
                .fill(Color(hex: 0xBFE9FF))
                .frame(width: size * 0.06, height: size * 0.09)
                .offset(x: -size * 0.16, y: size * CGFloat(0.08 + 0.14 * drop))
                .opacity(1 - drop)
        case .sleepy:
            let rise = (t * 0.45).truncatingRemainder(dividingBy: 1)
            Text("z")
                .font(.system(size: size * CGFloat(0.18 + 0.1 * rise), weight: .heavy, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.8 * (1 - rise)))
                .offset(x: size * CGFloat(0.34 + 0.08 * rise), y: -size * CGFloat(0.18 + 0.2 * rise))
        case .working:
            EmptyView()
        }
    }

    // MARK: Animation values

    private struct Motion {
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var squash: CGFloat = 0
        var tilt: Double = 0
        var antennaTilt: Double = 0
    }

    private var motion: Motion {
        var m = Motion()
        switch mood {
        case .working:
            m.dy = CGFloat(sin(t * 4)) * size * 0.025
            m.antennaTilt = sin(t * 2.2) * 8
        case .happy:
            let hop = abs(sin(t * 5.2))
            m.dy = -CGFloat(hop) * size * 0.12
            m.squash = CGFloat(pow(1 - hop, 6)) * 0.1
            m.antennaTilt = sin(t * 10.4) * 14
        case .alert:
            let burst = t.truncatingRemainder(dividingBy: 1.6) < 0.45
            m.dx = burst ? CGFloat(sin(t * 38)) * size * 0.025 : 0
            m.antennaTilt = burst ? sin(t * 38) * 12 : 0
        case .sad:
            m.dy = size * 0.03
            m.tilt = -5
            m.antennaTilt = -22
        case .sleepy:
            let breath = sin(t * 1.4)
            m.squash = CGFloat(breath) * 0.025
            m.antennaTilt = -10 + breath * 4
        }
        return m
    }

    /// Eyes close for a split second every few seconds.
    private var blink: CGFloat {
        let cycle = (t + Double(size)).truncatingRemainder(dividingBy: 3.7)
        return cycle < 0.12 ? 0.15 : 1
    }

    /// Pupils drift side to side while reading code.
    private var lookX: CGFloat {
        mood == .working ? CGFloat(sin(t * 1.3)) * size * 0.04 : 0
    }

    private var bulbColor: Color {
        switch mood {
        case .working: return Palette.blue
        case .happy: return Palette.green
        case .alert: return Palette.amber
        case .sad: return Palette.red
        case .sleepy: return Color.white.opacity(0.5)
        }
    }

    private var bulbGlow: CGFloat {
        switch mood {
        case .working: return CGFloat(0.5 + 0.5 * sin(t * 3))
        case .alert: return CGFloat(0.5 + 0.5 * sin(t * 9))
        case .sleepy: return 0.2
        default: return 1
        }
    }
}

// MARK: - Little shapes

/// A shallow arc: ∩ when `up` (happy eyes, frown), ∪ otherwise.
private struct ArcShape: Shape {
    var up: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if up {
            p.move(to: CGPoint(x: r.minX, y: r.maxY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY), control: CGPoint(x: r.midX, y: r.minY - r.height * 0.6))
        } else {
            p.move(to: CGPoint(x: r.minX, y: r.minY))
            p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY + r.height * 0.6))
        }
        return p
    }
}

/// An open smile.
private struct HalfDisc: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.minY), control: CGPoint(x: r.midX, y: r.maxY * 1.9))
        p.closeSubpath()
        return p
    }
}

/// Four-point twinkle.
struct Sparkle: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let w = r.width / 2, h = r.height / 2
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: c.y - h))
        p.addQuadCurve(to: CGPoint(x: c.x + w, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + h), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x - w, y: c.y), control: c)
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - h), control: c)
        p.closeSubpath()
        return p
    }
}

private struct Teardrop: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY - r.width / 2), control: CGPoint(x: r.maxX, y: r.midY))
        p.addArc(center: CGPoint(x: r.midX, y: r.maxY - r.width / 2), radius: r.width / 2,
                 startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: CGPoint(x: r.minX, y: r.midY))
        return p
    }
}

// MARK: - Celebration

/// A one-shot burst of confetti behind a "done" banner.
struct ConfettiBurst: View {
    var count = 16
    @State private var progress: CGFloat = 0

    private static let colors: [Color] = [Palette.green, Palette.amber, Palette.blue, Color(hex: 0xFF8FB1), Color(hex: 0x9BEAF2), .white]

    var body: some View {
        ZStack {
            ForEach(0..<count, id: \.self) { i in
                let angle = Double(i) / Double(count) * 2 * .pi + Double(i % 3) * 0.3
                let distance = 26 + CGFloat((i * 37) % 22)
                RoundedRectangle(cornerRadius: 1)
                    .fill(Self.colors[i % Self.colors.count])
                    .frame(width: i % 2 == 0 ? 4 : 3, height: i % 2 == 0 ? 7 : 3)
                    .rotationEffect(.degrees(Double(progress) * Double(180 + i * 40)))
                    .offset(x: CGFloat(cos(angle)) * distance * progress,
                            y: CGFloat(sin(angle)) * distance * progress + 10 * progress * progress)
                    .opacity(Double(1 - progress * progress))
            }
        }
        .allowsHitTesting(false)
        .onAppear {
            guard !Theme.reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.1)) { progress = 1 }
        }
    }
}
