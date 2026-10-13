import AppKit
import SwiftUI

/// Fixed geometry prevents late image downloads from moving scores or click targets.
struct TeamLogo: View {
    let team: SportsTeam
    var size: CGFloat = 28
    @State private var image: NSImage?
    @State private var loadedURL: URL?
    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 160
        return cache
    }()

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22).fill(Color.white.opacity(0.08))
            if let url = team.logoURL, let logo = Self.cache.object(forKey: url as NSURL) ?? (loadedURL == url ? image : nil) {
                Image(nsImage: logo).resizable().scaledToFit().padding(size * 0.08)
            } else {
                Text(String(team.abbreviation.prefix(3)))
                    .font(.system(size: size * 0.29, weight: .bold, design: .rounded))
                    .foregroundStyle(team.tint).lineLimit(1).minimumScaleFactor(0.6)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true) // Adjacent team label already names the team.
        .task(id: team.logoURL) {
            image = nil
            loadedURL = nil
            guard let url = team.logoURL else { return }
            if let cached = Self.cache.object(forKey: url as NSURL) {
                image = cached; loadedURL = url; return
            }
            do {
                let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard !Task.isCancelled, let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode), data.count <= 2_000_000,
                      let logo = NSImage(data: data) else { return }
                Self.cache.setObject(logo, forKey: url as NSURL)
                image = logo
                loadedURL = url
            } catch { /* Keep the team abbreviation visible while offline. */ }
        }
    }
}
