import SwiftUI

/// The island drops down to show a notification, agent ping, or alert, then tucks back in.
/// A hairline along the bottom shows how long it will stay.
struct BannerView: View {
    @ObservedObject var model: IslandModel
    let banner: Banner

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchSize.height)
            HStack(alignment: .center, spacing: Theme.Space.m) {
                BannerIconView(icon: banner.icon, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if let source = sourceName {
                            Text(source)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.inkTertiary)
                                .lineLimit(1)
                                .layoutPriority(-1)
                        }
                        Spacer(minLength: 4)
                        if banner.sticky {
                            Button {
                                model.dismissBanner()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.inkTertiary)
                                    .frame(width: 18, height: 18)
                                    .background(Circle().fill(Theme.surface))
                            }
                            .buttonStyle(PressableStyle())
                        } else {
                            Text("now")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.inkTertiary)
                        }
                    }
                    Text(banner.title)
                        .font(Theme.Font.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if !banner.body.isEmpty {
                        Text(banner.body)
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

            if !banner.sticky {
                CountdownHairline(duration: banner.duration ?? model.config.bannerSeconds, tint: banner.style.tint)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 7)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.tapBanner(banner) }
    }

    /// The small line above the title: the app's name for mirrored notifications, the event type otherwise.
    private var sourceName: String? {
        switch banner.icon {
        case .app(let bundleID): return AppIcons.name(for: bundleID)
        case .file: return "Shelf"
        case .symbol:
            switch banner.style {
            case .success: return banner.activityID == nil ? "Done" : "Finished"
            case .attention: return "Needs you"
            case .failure: return "Failed"
            case .info: return nil
            }
        }
    }
}

/// Shrinks from full width to nothing over the banner's lifetime.
private struct CountdownHairline: View {
    let duration: TimeInterval
    let tint: Color
    @State private var remaining: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Capsule()
                .fill(tint.opacity(0.5))
                .frame(width: geo.size.width * remaining)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(height: 2)
        .onAppear {
            withAnimation(.linear(duration: duration)) { remaining = 0 }
        }
    }
}
