import SwiftUI

/// Pip: a matte white companion, drawn with native shapes at every size.
struct Buddy: View {
    var mood: BuddyMood
    var size: CGFloat = 22
    var badge: AgentKind? = nil
    var animating = true

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15,
                                paused: !animating || mood == .sleepy || Theme.reduceMotion)) { context in
            BuddyFigure(mood: mood, size: size,
                        t: animating && mood != .sleepy && !Theme.reduceMotion ? context.date.timeIntervalSinceReferenceDate : 0)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .topLeading) {
            if let badge, size >= 28 {
                Image(systemName: badge.symbol)
                    .font(.system(size: size * 0.13, weight: .bold))
                    .foregroundStyle(Color.white)
                    .frame(width: size * 0.24, height: size * 0.24)
                    .background(Circle().fill(badge.tint))
                    .overlay(Circle().strokeBorder(Theme.surface, lineWidth: max(1, size * 0.025)))
                    .offset(x: size * 0.08, y: size * 0.14)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pip · \(accessibilityText)")
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

private struct BuddyFigure: View {
    let mood: BuddyMood
    let size: CGFloat
    let t: Double
    private let bodyColor = Color(hex: 0xF1F4F8)
    private let ink = Color(hex: 0x171D29)
    private var bounce: CGFloat { mood == .happy ? -CGFloat(abs(sin(t * 4))) * size * 0.07 : 0 }
    private var drift: CGFloat { mood == .working ? CGFloat(sin(t * 2)) * size * 0.018 : 0 }
    private var blink: CGFloat { t > 0 && t.truncatingRemainder(dividingBy: 4.2) < 0.13 ? 0.15 : 1 }
    private var look: CGFloat { mood == .working ? CGFloat(sin(t * 0.8)) * size * 0.035 : 0 }

    var body: some View {
        ZStack {
            if size >= 36 {
                Circle().fill(bodyColor).frame(width: size * 0.105, height: size * 0.105)
                    .offset(x: -size * 0.43, y: size * 0.12 + drift)
                Capsule().fill(bodyColor).frame(width: size * 0.10, height: size * 0.18)
                    .rotationEffect(.degrees(mood == .happy ? -38 + sin(t * 5) * 18 : -28))
                    .offset(x: size * 0.43, y: -size * 0.04 - drift)
            }
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(bodyColor)
                .frame(width: size * 0.78, height: size * 0.64)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.7), lineWidth: max(0.5, size * 0.012))
                }
                .shadow(color: Color.black.opacity(0.12), radius: size * 0.04, y: size * 0.025)
                .overlay {
                    HStack(spacing: size * 0.17) { eye; eye }
                        .offset(x: look, y: size * 0.018)
                }
                .rotationEffect(.degrees(mood == .sad ? -7 : mood == .happy ? sin(t * 4) * 3 : 0))
                .offset(y: drift + bounce)
            if mood == .alert {
                Text("!").font(.system(size: size * 0.17, weight: .heavy, design: .rounded))
                    .foregroundStyle(Palette.amber).offset(x: size * 0.35, y: -size * 0.27)
            }
            if mood == .sleepy, size >= 28 {
                Text("z").font(.system(size: size * 0.14, weight: .semibold, design: .rounded))
                    .foregroundStyle(Theme.inkSecondary).offset(x: size * 0.37, y: -size * 0.27)
            }
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private var eye: some View {
        switch mood {
        case .happy:
            ArcShape(up: true).stroke(ink, style: StrokeStyle(lineWidth: max(1.2, size * 0.033), lineCap: .round))
                .frame(width: size * 0.09, height: size * 0.06)
        case .sleepy:
            Capsule().fill(ink).frame(width: size * 0.09, height: max(1.3, size * 0.024))
        case .sad:
            Ellipse().fill(ink).frame(width: size * 0.085, height: size * 0.065)
                .rotationEffect(.degrees(-12))
        case .alert:
            Ellipse().fill(ink).frame(width: size * 0.10, height: size * 0.16)
        case .working:
            Ellipse().fill(ink).frame(width: size * 0.085, height: max(1.4, size * 0.12 * blink))
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
