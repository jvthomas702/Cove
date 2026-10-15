import SwiftUI
import UniformTypeIdentifiers

/// The notch silhouette: a flat top that hugs the screen edge, soft concave "ears" where it meets the
/// menu bar, and Apple-style continuous (squircle) corners at the bottom — not plain circular arcs.
struct IslandShape: Shape {
    var ear: CGFloat
    var bottomRadius: CGFloat
    var roundedTop = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, bottomRadius) }
        set { ear = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        if roundedTop {
            return Path(roundedRect: r, cornerRadius: bottomRadius, style: .continuous)
        }
        let e = max(0, min(ear, r.width / 4))
        let radius = max(0, min(bottomRadius, (r.width - 2 * e) / 2, r.height))
        // Body: a continuous rounded rect whose top corners sit above the frame (so only the bottom ones show).
        let body = Path(
            roundedRect: CGRect(x: r.minX + e, y: r.minY - radius * 2, width: r.width - 2 * e, height: r.height + radius * 2),
            cornerRadius: radius,
            style: .continuous
        )
        guard e > 0.5 else { return body }

        var ears = Path()
        // Left ear: fills the corner between the menu bar edge and the island's side.
        ears.move(to: CGPoint(x: r.minX, y: r.minY))
        ears.addCurve(
            to: CGPoint(x: r.minX + e, y: r.minY + e),
            control1: CGPoint(x: r.minX + e * 0.62, y: r.minY),
            control2: CGPoint(x: r.minX + e, y: r.minY + e * 0.38)
        )
        ears.addLine(to: CGPoint(x: r.minX + e + 1, y: r.minY + e))
        ears.addLine(to: CGPoint(x: r.minX + e + 1, y: r.minY))
        ears.closeSubpath()
        // Right ear, mirrored.
        ears.move(to: CGPoint(x: r.maxX, y: r.minY))
        ears.addCurve(
            to: CGPoint(x: r.maxX - e, y: r.minY + e),
            control1: CGPoint(x: r.maxX - e * 0.62, y: r.minY),
            control2: CGPoint(x: r.maxX - e, y: r.minY + e * 0.38)
        )
        ears.addLine(to: CGPoint(x: r.maxX - e - 1, y: r.minY + e))
        ears.addLine(to: CGPoint(x: r.maxX - e - 1, y: r.minY))
        ears.closeSubpath()
        return body.union(ears)
    }
}

/// Shared namespace so album art (and the agent glyph) can fly between the compact wings and the open island.
private struct IslandNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var islandNamespace: Namespace.ID? {
        get { self[IslandNamespaceKey.self] }
        set { self[IslandNamespaceKey.self] = newValue }
    }
}

extension View {
    /// `matchedGeometryEffect` when a namespace is available; a no-op otherwise.
    @ViewBuilder
    func islandMatched(_ id: String, in namespace: Namespace.ID?, isSource: Bool = true) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
        } else {
            self
        }
    }
}

struct IslandRootView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        IslandShell(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, model.presentation == .expanded ? model.config.islandTheme.colorScheme : .dark)
    }
}

struct IslandShell: View {
    @ObservedObject var model: IslandModel
    @State private var dropTargeted = false
    @Namespace private var namespace

    var body: some View {
        let p = model.presentation
        let size = model.currentSize
        let shape = IslandShape(ear: p == .idle ? 0 : IslandModel.ear, bottomRadius: radius(for: p), roundedTop: p == .expanded)
        let isOpen = p == .expanded || p == .banner || p == .approval

        ZStack(alignment: .top) {
            shape
                .fill(p == .expanded ? Theme.background : Color.black)
                .shadow(color: .black.opacity(isOpen ? 0.5 : 0), radius: 18, y: 8)

            content(for: p)
                .padding(.horizontal, p == .idle ? 0 : IslandModel.ear)
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
                .transition(.islandMorph)
                .id(p)
        }
        .overlay(alignment: .top) {
            if p == .expanded {
                UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10)
                    .fill(Color.black).frame(width: model.notchSize.width, height: model.notchSize.height)
                    .allowsHitTesting(false)
            }
        }
        // A faint rim along the lower edge gives the open island some depth against dark wallpapers.
        .overlay {
            if isOpen {
                shape.stroke(Theme.hairline, lineWidth: 1)
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if let glow = glowColor(for: p) {
                GlowRim(shape: shape, color: glow)
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
        .onChange(of: p) { _, next in
            if next == .expanded || next == .approval { Haptics.tap() }
        }
        .animation(Theme.morph, value: p)
        .animation(Theme.morph, value: size)
        .environment(\.islandNamespace, namespace)
    }

    private func radius(for p: IslandModel.Presentation) -> CGFloat {
        switch p {
        case .idle: return 10
        case .compact: return 14
        case .banner: return Theme.Radius.islandBanner
        case .expanded, .approval: return Theme.Radius.islandExpanded
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
        case .approval:
            return Palette.amber
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
        case .approval:
            if let request = model.approvals.first {
                ApprovalView(model: model, request: request)
            } else {
                Color.clear
            }
        }
    }
}

/// A slow "breathing" outline for states that need you (permission prompts, alerts).
private struct GlowRim: View {
    let shape: IslandShape
    let color: Color
    @State private var bright = false

    var body: some View {
        shape
            .stroke(color.opacity(bright ? 0.75 : 0.3), lineWidth: 1.2)
            .shadow(color: color.opacity(bright ? 0.45 : 0.15), radius: bright ? 8 : 4)
            .allowsHitTesting(false)
            .onAppear {
                guard !Theme.reduceMotion else { bright = true; return }
                withAnimation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true)) { bright = true }
            }
    }
}
