import SwiftUI

/// The island drops down to show a notification, agent ping, or alert, then tucks back in.
struct BannerView: View {
    @ObservedObject var model: IslandModel
    let banner: Banner

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchSize.height)
            HStack(spacing: 12) {
                BannerIconView(icon: banner.icon)
                    .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(banner.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        if banner.sticky {
                            IconButton(systemImage: "xmark", size: 9) { model.dismissBanner() }
                                .foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    if !banner.body.isEmpty {
                        Text(banner.body)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(2)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { model.tapBanner(banner) }
    }
}
