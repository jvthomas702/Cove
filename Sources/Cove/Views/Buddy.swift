import AppKit
import SwiftUI

/// Nori — Cove's buddy. A little black pill with glowing eyes that sits in the island as if it were part
/// of it: the body is as black as the island, so what you see is its eyes and a thin rim that lights up
/// in the status color. Drawn entirely with SwiftUI shapes, so it stays crisp from 18 pt to 44 pt.
///
/// Every expression is a handful of numbers (`Pose`), so a mood change springs from one face to the
/// next instead of cutting, and the body gets a little jolt when it happens.
struct Buddy: View {
    var mood: BuddyMood
    var size: CGFloat = 22
    /// Small agent badge (Claude sparkle, terminal…) shown at larger sizes.
    var badge: AgentKind? = nil

    @State private var previous: BuddyMood?
    @State private var changedAt = Date()
    @State private var settled = false

    var body: some View {
        let still = Theme.reduceMotion
        // Napping Nori is on screen all day, so once it has settled it breathes at a low frame rate.
        let slow = mood == .sleepy && settled
        TimelineView(.animation(minimumInterval: slow ? 1.0 / 6 : 1.0 / 30, paused: still)) { context in
            NoriFigure(
                mood: mood,
                previous: previous,
                since: still ? 10 : context.date.timeIntervalSince(changedAt),
                size: size,
                t: still ? 0 : context.date.timeIntervalSinceReferenceDate,
                followsPointer: !still
            )
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
        .onChange(of: mood) { old, _ in
            previous = old
            changedAt = Date()
            settled = false
        }
        .task(id: changedAt) {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            settled = true
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

// MARK: - Figure

/// One frame of Nori. Pure function of its inputs, so it can also be rendered offscreen frame by frame.
struct NoriFigure: View {
    let mood: BuddyMood
    /// The mood Nori is springing away from; nil when it just appeared.
    let previous: BuddyMood?
    /// Seconds since `mood` took over.
    let since: Double
    let size: CGFloat
    let t: Double
    var followsPointer = false

    private static let sparkleX: [CGFloat] = [-0.4, 0.42, 0.3]
    private static let sparkleY: [CGFloat] = [-0.2, -0.3, 0.32]
    private static let eyeInk = Color(hex: 0xF4F8FF)

    /// Beside the notch Nori is ~30 pt, so its eyes get bigger and fine details are dropped.
    private var small: Bool { size < 36 }

    var body: some View {
        let p = CGFloat(Bounce.settle(since))
        let settledP = min(p, 1)
        let target = Pose(mood)
        let from = previous.map(Pose.init) ?? target.hidden
        var pose = Pose.mix(from, target, p)
        pose.glow *= Pose.pulse(previous ?? mood, t) * (1 - settledP) + Pose.pulse(mood, t) * settledP
        pose.glow = max(0, min(pose.glow, 1))

        var m = Motion.mix(Motion(previous ?? mood, t: t, size: size), Motion(mood, t: t, size: size), settledP)
        if previous != nil {
            // The jolt of changing moods: a quick squash-and-stretch that dies out.
            m.squash += CGFloat(0.16 * exp(-since * 6) * sin(since * 22))
        } else {
            m.scale *= 0.35 + 0.65 * p
        }
        if followsPointer, mood != .sleepy, let x = Self.pointerLook() {
            m.look.x = x
        }
        let open = pose.open * (blinks ? blink : 1)

        let bodyW = size * 0.86
        let bodyH = size * 0.6
        let shape = RoundedRectangle(cornerRadius: bodyH * 0.46, style: .continuous)
        let rim = max(0.8, size * (small ? 0.036 : 0.028))

        return ZStack {
            if pose.glow > 0.2 && size >= 20 {
                rimLight(shape, pose: pose, width: rim * 2.4)
                    .blur(radius: size * 0.07)
                    .opacity(0.85)
            }
            shape.fill(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.02), .black],
                                      startPoint: .top, endPoint: .bottom))
            shape.strokeBorder(Color.white.opacity(0.16), lineWidth: rim)
            rimLight(shape, pose: pose, width: rim)
            eyes(pose: pose, open: open, look: m.look)
        }
        .frame(width: bodyW, height: bodyH)
        .scaleEffect(x: (1 + m.squash) * m.scale, y: (1 - m.squash) * m.scale, anchor: .bottom)
        .rotationEffect(.degrees(m.tilt))
        .offset(x: m.dx, y: m.dy + size * 0.1)
        .frame(width: size, height: size)
        .overlay { accessories(pose: pose, look: m.look).opacity(Double(settledP)) }
    }

    // MARK: Rim

    /// The status-colored rim. While working, two bright arcs chase each other around it.
    private func rimLight(_ shape: RoundedRectangle, pose: Pose, width: CGFloat) -> some View {
        let c = pose.color
        let chase = AngularGradient(
            gradient: Gradient(colors: [c.opacity(0), c, c.opacity(0), c, c.opacity(0)]),
            center: .center,
            angle: .degrees(t * 220)
        )
        return ZStack {
            shape.strokeBorder(c, lineWidth: width).opacity(Double(pose.glow * (1 - pose.chase)))
            shape.strokeBorder(chase, lineWidth: width).opacity(Double(pose.glow * pose.chase))
        }
    }

    // MARK: Eyes

    private func eyes(pose: Pose, open: CGFloat, look: CGPoint) -> some View {
        let s: CGFloat = small ? 1.18 : 1
        let w = size * 0.15 * s
        let h = size * 0.22 * s
        let gap = size * 0.25 * s
        let eye = EyeShape(open: open, smile: pose.smile, slant: pose.slant)
        return HStack(spacing: gap - w) {
            eye.fill(Self.eyeInk).frame(width: w, height: h)
            eye.fill(Self.eyeInk).frame(width: w, height: h).scaleEffect(x: -1, y: 1)
        }
        .shadow(color: small ? .clear : pose.color.opacity(Double(0.7 * pose.glow)), radius: size * 0.05)
        .offset(x: look.x * size * 0.07, y: look.y * size * 0.05 - size * 0.01)
    }

    /// Happy and sleepy eyes are already shut-ish; the others blink.
    private var blinks: Bool { mood == .working || mood == .alert || mood == .sad }

    /// Eyes close for a split second every few seconds, at uneven intervals, sometimes twice in a row.
    private var blink: CGFloat {
        let period = 3.4
        let seed = Double(size) * 0.37
        let k = ((t + seed) / period).rounded(.down)
        let local = t + seed - k * period - Noise.value(k) * 1.6
        func shut(_ x: Double) -> Double { (0..<0.16).contains(x) ? sin(.pi * x / 0.16) : 0 }
        let twice = Noise.value(k + 7) > 0.7 ? shut(local - 0.24) : 0
        return CGFloat(1 - 0.94 * max(shut(local), twice))
    }

    /// Glances toward the pointer when it's near the top-center of a screen, where the island lives.
    @MainActor private static func pointerLook() -> CGFloat? {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) else { return nil }
        let dx = mouse.x - screen.frame.midX
        guard screen.frame.maxY - mouse.y < 240, abs(dx) < 520 else { return nil }
        return max(-1, min(1, dx / 240))
    }

    // MARK: Accessories

    @ViewBuilder
    private func accessories(pose: Pose, look: CGPoint) -> some View {
        switch mood {
        case .happy:
            ForEach(0..<3, id: \.self) { i in
                let phase = t * 2.6 + Double(i) * 2.1
                Sparkle()
                    .fill(i == 1 ? Palette.green : Color.white)
                    .frame(width: size * 0.15, height: size * 0.15)
                    .scaleEffect(CGFloat(0.3 + 0.7 * abs(sin(phase))))
                    .rotationEffect(.degrees(phase * 20))
                    .opacity(0.25 + 0.75 * abs(sin(phase)))
                    .offset(x: Self.sparkleX[i] * size, y: Self.sparkleY[i] * size)
            }
        case .alert:
            // Pops up at the start of each nudge, then settles.
            let local = t.truncatingRemainder(dividingBy: Motion.alertCycle)
            let pop = local < 0.5 ? 1 + 0.35 * sin(.pi * local / 0.5) : 1
            Text("!")
                .font(.system(size: size * 0.3, weight: .black, design: .rounded))
                .foregroundStyle(Palette.amber)
                .shadow(color: Palette.amber.opacity(0.6), radius: size * 0.04)
                .scaleEffect(CGFloat(pop))
                .offset(x: size * 0.42, y: -size * 0.24)
        case .sad:
            // A tear rolls from under one eye.
            let drop = (t * 0.6).truncatingRemainder(dividingBy: 1)
            Teardrop()
                .fill(Color(hex: 0xBFE9FF))
                .frame(width: size * 0.06, height: size * 0.09)
                .offset(x: -size * 0.13 + look.x * size * 0.07, y: size * CGFloat(0.16 + 0.16 * drop))
                .opacity(drop < 0.15 ? drop / 0.15 : 1 - (drop - 0.15) / 0.85)
        case .sleepy:
            ForEach(0..<2, id: \.self) { i in
                let rise = (t * 0.35 + Double(i) * 0.5).truncatingRemainder(dividingBy: 1)
                Text("z")
                    .font(.system(size: size * CGFloat(0.15 + 0.1 * rise), weight: .heavy, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.75 * sin(.pi * rise)))
                    .offset(x: size * CGFloat(0.3 + 0.12 * rise + 0.03 * sin(rise * 9)),
                            y: -size * CGFloat(0.1 + 0.28 * rise))
            }
        case .working:
            EmptyView()
        }
    }
}

// MARK: - Pose

/// Everything about Nori's face that changes between moods, as numbers that can be blended.
private struct Pose {
    var open: CGFloat    // eye openness: 0 shut … 1 open … 1.2 wide
    var smile: CGFloat   // −1 ∪ (content, asleep) … 0 round … 1 ∩ (happy)
    var slant: CGFloat   // + inner corners down (focused) … − inner corners up (worried)
    var glow: CGFloat    // rim light, 0…1
    var chase: CGFloat   // 0 steady rim … 1 arcs chasing around it
    var red: Double, green: Double, blue: Double

    init(open: CGFloat, smile: CGFloat, slant: CGFloat, glow: CGFloat, chase: CGFloat, hex: UInt32) {
        self.open = open; self.smile = smile; self.slant = slant; self.glow = glow; self.chase = chase
        red = Double((hex >> 16) & 0xFF) / 255
        green = Double((hex >> 8) & 0xFF) / 255
        blue = Double(hex & 0xFF) / 255
    }

    init(_ mood: BuddyMood) {
        switch mood {
        case .working: self.init(open: 0.85, smile: 0, slant: 0.3, glow: 0.95, chase: 1, hex: 0x3A9BFF)
        case .happy: self.init(open: 1, smile: 1, slant: 0, glow: 1, chase: 0, hex: 0x30D158)
        case .alert: self.init(open: 1.18, smile: 0, slant: -0.25, glow: 1, chase: 0, hex: 0xFFB340)
        case .sad: self.init(open: 0.5, smile: 0, slant: -0.9, glow: 0.6, chase: 0, hex: 0xFF453A)
        case .sleepy: self.init(open: 0, smile: -0.7, slant: 0, glow: 0.14, chase: 0, hex: 0xC8D4FF)
        }
    }

    /// Eyes shut and rim dark: where Nori starts when it first appears.
    var hidden: Pose {
        var p = self
        p.open = 0
        p.glow = 0
        return p
    }

    var color: Color { Color(.sRGB, red: red, green: green, blue: blue) }

    /// `p` may overshoot 1 a little (spring), which makes the eyes pop; colors are clamped.
    static func mix(_ a: Pose, _ b: Pose, _ p: CGFloat) -> Pose {
        let c = Double(max(0, min(p, 1)))
        func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * p }
        var out = b
        out.open = max(0, l(a.open, b.open))
        out.smile = l(a.smile, b.smile)
        out.slant = l(a.slant, b.slant)
        out.glow = a.glow + (b.glow - a.glow) * CGFloat(c)
        out.chase = a.chase + (b.chase - a.chase) * CGFloat(c)
        out.red = a.red + (b.red - a.red) * c
        out.green = a.green + (b.green - a.green) * c
        out.blue = a.blue + (b.blue - a.blue) * c
        return out
    }

    /// How the rim's brightness throbs in each mood.
    static func pulse(_ mood: BuddyMood, _ t: Double) -> CGFloat {
        switch mood {
        case .alert: return CGFloat(0.55 + 0.45 * sin(t * 9))
        case .happy: return CGFloat(0.8 + 0.2 * sin(t * 6.6))
        case .sad: return CGFloat(0.7 + 0.3 * sin(t * 1.4))
        default: return 1
        }
    }
}

// MARK: - Motion

/// Whole-body movement for a mood at time `t`.
private struct Motion {
    var dx: CGFloat = 0
    var dy: CGFloat = 0
    var squash: CGFloat = 0     // + wider and shorter, − taller and thinner
    var tilt: Double = 0
    var scale: CGFloat = 1
    var look = CGPoint.zero     // where the eyes point, −1…1 each way

    static let hopCycle = 0.95
    static let alertCycle = 1.7

    init() {}

    init(_ mood: BuddyMood, t: Double, size: CGFloat) {
        switch mood {
        case .working:
            // Reading: eyes dart along and down a line, the head follows a little.
            dy = CGFloat(sin(t * 3.2)) * size * 0.015
            look = Self.saccade(t)
            look.y = 0.25 + look.y * 0.4
            tilt = Double(look.x) * 4
        case .happy:
            // Crouch, jump with a stretch, land with a squash; lean the other way each hop.
            let n = (t / Self.hopCycle).rounded(.down)
            let u = t / Self.hopCycle - n
            let side: Double = Int(n) % 2 == 0 ? 1 : -1
            if u < 0.18 {
                squash = CGFloat(0.14 * sin(.pi * u / 0.18))
            } else if u < 0.78 {
                let k = (u - 0.18) / 0.6
                dy = -CGFloat(sin(.pi * k)) * size * 0.17
                squash = -CGFloat(0.09 * cos(.pi * k))
                tilt = side * 8 * sin(.pi * k)
            } else {
                let k = (u - 0.78) / 0.22
                squash = CGFloat(0.09 * cos(.pi * k / 2))
            }
            look = CGPoint(x: 0, y: -0.25)
        case .alert:
            // Every so often: two quick hops and a shake, like tapping you on the shoulder.
            let local = t.truncatingRemainder(dividingBy: Self.alertCycle)
            if local < 0.55 {
                let fade = 1 - local / 0.55
                dx = CGFloat(sin(local * 48) * fade) * size * 0.035
                dy = -CGFloat(abs(sin(local * 2 * .pi / 0.55 * 2))) * size * 0.06
                tilt = sin(local * 48) * 5 * fade
            } else {
                squash = CGFloat(sin(t * 2.4)) * 0.015
            }
            look = CGPoint(x: 0, y: -0.15)
        case .sad:
            // Sunk down, slowly swaying, looking at the floor.
            dy = size * 0.05 + CGFloat(sin(t * 1.2)) * size * 0.008
            squash = 0.05
            tilt = -4 + sin(t * 0.9) * 2
            look = CGPoint(x: CGFloat(sin(t * 0.5)) * 0.25, y: 0.75)
        case .sleepy:
            let breath = sin(t * 1.3)
            squash = CGFloat(breath) * 0.035
            dy = size * 0.02
            tilt = 3
            look = CGPoint(x: 0, y: 0.35)
        }
    }

    static func mix(_ a: Motion, _ b: Motion, _ p: CGFloat) -> Motion {
        func l(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * p }
        var m = Motion()
        m.dx = l(a.dx, b.dx)
        m.dy = l(a.dy, b.dy)
        m.squash = l(a.squash, b.squash)
        m.tilt = a.tilt + (b.tilt - a.tilt) * Double(p)
        m.scale = l(a.scale, b.scale)
        m.look = CGPoint(x: l(a.look.x, b.look.x), y: l(a.look.y, b.look.y))
        return m
    }

    /// Eyes hold still, then dart to a new spot — the way eyes actually move — instead of drifting.
    static func saccade(_ t: Double) -> CGPoint {
        let hold = 1.3
        let k = (t / hold).rounded(.down)
        let local = t - k * hold
        func spot(_ i: Double) -> CGPoint {
            CGPoint(x: CGFloat(Noise.value(i) * 2 - 1), y: CGFloat(Noise.value(i + 0.5) * 2 - 1))
        }
        let a = spot(k - 1), b = spot(k)
        let f = CGFloat(Bounce.ease(min(local / 0.14, 1)))
        return CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f)
    }
}

// MARK: - Helpers

private enum Bounce {
    /// 0 → 1 with a small overshoot, like a slightly bouncy spring; exactly 1 after a second and a half.
    static func settle(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1.5 else { return 1 }
        return 1 - exp(-t * 8) * cos(t * 13)
    }

    static func ease(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
}

private enum Noise {
    /// Repeatable pseudo-random value in 0..<1 for an index.
    static func value(_ i: Double) -> Double {
        let x = sin(i * 12.9898 + 4.1414) * 43_758.5453
        return x - x.rounded(.down)
    }
}

// MARK: - Little shapes

/// One eye, as a filled shape whose top and bottom edges are curves. Blending the three numbers moves
/// smoothly between a round eye, a ∩ happy eye, a ∪ sleeping eye and a slanted focused or worried eye.
/// Drawn as the left eye (inner corner on the right); mirror it for the right eye.
private struct EyeShape: Shape {
    var open: CGFloat
    var smile: CGFloat
    var slant: CGFloat

    func path(in r: CGRect) -> Path {
        let half = r.height / 2
        let lid = max(half * open, r.height * 0.11) * 1.33
        let band = r.height * 0.42
        let up = max(smile, 0)
        let sag = max(-smile, 0) * half * 0.9
        let cy = r.midY + up * half * 0.3

        let topOuter = cy - lid * (1 + 0.6 * slant) + sag
        let topInner = cy - lid * (1 - 0.6 * slant) + sag
        let bottomOuter = (cy + lid + sag) + ((topOuter + band) - (cy + lid + sag)) * up
        let bottomInner = (cy + lid + sag) + ((topInner + band) - (cy + lid + sag)) * up

        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: cy))
        p.addCurve(to: CGPoint(x: r.maxX, y: cy),
                   control1: CGPoint(x: r.minX, y: topOuter),
                   control2: CGPoint(x: r.maxX, y: topInner))
        p.addCurve(to: CGPoint(x: r.minX, y: cy),
                   control1: CGPoint(x: r.maxX, y: bottomInner),
                   control2: CGPoint(x: r.minX, y: bottomOuter))
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

// MARK: - Film (CI)

/// Renders Nori offscreen, frame by frame, walking through every mood: a still sheet plus numbered
/// frames for an animated preview. Used by the debug API in CI, where there's no one to watch.
@MainActor
enum BuddyFilm {
    private static let script: [(BuddyMood, Double)] = [
        (.sleepy, 1.6), (.working, 2.8), (.alert, 2.0), (.working, 1.2), (.happy, 2.4), (.sad, 2.2), (.sleepy, 1.6),
    ]
    private static let moods: [(BuddyMood, String)] = [
        (.sleepy, "Idle"), (.working, "Working"), (.alert, "Needs you"), (.happy, "Done"), (.sad, "Failed"),
    ]

    static func render(to dir: URL, fps: Double = 24) {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        write(sheet, to: dir.appendingPathComponent("sheet.png"))

        var start = 0.0
        var frame = 0
        var previous: BuddyMood?
        for (mood, length) in script {
            var local = 0.0
            while local < length {
                let t = start + local
                let view = HStack(spacing: 28) {
                    NoriFigure(mood: mood, previous: previous, since: local, size: 96, t: t)
                    NoriFigure(mood: mood, previous: previous, since: local, size: 30, t: t)
                }
                .padding(18)
                .background(Color.black)
                write(view, to: dir.appendingPathComponent(String(format: "f%04d.png", frame)))
                frame += 1
                local += 1 / fps
            }
            start += length
            previous = mood
        }
        FileManager.default.createFile(atPath: dir.appendingPathComponent("done").path, contents: Data())
    }

    /// Every mood side by side, big and at notch size.
    private static var sheet: some View {
        HStack(spacing: 22) {
            ForEach(moods.indices, id: \.self) { i in
                VStack(spacing: 10) {
                    NoriFigure(mood: moods[i].0, previous: nil, since: 10, size: 72, t: 0.6)
                    NoriFigure(mood: moods[i].0, previous: nil, since: 10, size: 30, t: 0.6)
                    Text(moods[i].1)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
        }
        .padding(20)
        .background(Color.black)
    }

    private static func write<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
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
