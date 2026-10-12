import SwiftUI
import UniformTypeIdentifiers

/// The notch silhouette: flat top that hugs the screen edge, small concave "ears" where it meets
/// the menu bar, and rounded bottom corners — the same shape as the iPhone's Dynamic Island cutout.
struct IslandShape: Shape {
    var ear: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottomRadius) }
        set { ear = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let e = min(ear, r.width / 4)
        let b = min(bottomRadius, (r.height - e) / 2, (r.width - 2 * e) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + e, y: r.minY + e), control: CGPoint(x: r.minX + e, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + e, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + e + b, y: r.maxY), control: CGPoint(x: r.minX + e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - e, y: r.maxY - b), control: CGPoint(x: r.maxX - e, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - e, y: r.minY + e))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - e, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        IslandShell(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }
}

struct IslandShell: View {
    @ObservedObject var model: IslandModel
    @State private var dropTargeted = false

    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.78)

    var body: some View {
        let p = model.presentation
        let size = model.size(for: p)
        let shape = IslandShape(ear: p == .idle ? 0 : IslandModel.ear, bottomRadius: radius(for: p))

        ZStack(alignment: .top) {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(p == .expanded || p == .banner ? 0.45 : 0), radius: 14, y: 6)

            content(for: p)
                .padding(.horizontal, p == .idle ? 0 : IslandModel.ear)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
                .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
                .id(p)
        }
        .overlay(alignment: .top) {
            if let glow = glowColor(for: p) {
                shape.stroke(glow.opacity(0.55), lineWidth: 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        // Hover is handled by IslandHostingView's tracking area (see NotchWindow.swift).
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            model.receiveDrop(providers)
            return true
        }
        .onChange(of: dropTargeted) { _, targeted in
            model.setDropTargeted(targeted)
        }
        .animation(spring, value: p)
        .animation(spring, value: model.notchSize)
    }

    private func radius(for p: IslandModel.Presentation) -> CGFloat {
        switch p {
        case .idle: return 9
        case .compact: return 12
        case .banner: return 24
        case .expanded: return 32
        }
    }

    private func glowColor(for p: IslandModel.Presentation) -> Color? {
        switch p {
        case .banner:
            guard let style = model.banner?.style, style != .info else { return nil }
            return style.tint
        case .compact:
            if case .attention? = model.compactItem { return Palette.amber }
            return nil
        default:
            return nil
        }
    }

    @ViewBuilder
    private func content(for p: IslandModel.Presentation) -> some View {
        switch p {
        case .idle:
            Color.clear
        case .compact:
            CompactView(model: model)
        case .banner:
            if let banner = model.banner {
                BannerView(model: model, banner: banner)
            } else {
                Color.clear
            }
        case .expanded:
            ExpandedView(model: model)
        }
    }
}
