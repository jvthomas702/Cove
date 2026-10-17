import Foundation
import os

/// Announces new releases from Cove's public distribution channel once per version.
/// Sparkle remains responsible for signed update checks, downloads and installation.
@MainActor
final class UpdateChecker {
    struct Release: Equatable {
        let version: String
        let url: URL
    }

    var onNewRelease: ((Release) -> Void)?

    private let currentVersion: String
    private var timer: Timer?
    private static let latestURL = URL(string: "https://api.github.com/repos/jvthomas702/Cove-updates/releases/latest")!
    private static let announcedKey = "lastAnnouncedRelease"

    init(currentVersion: String) {
        self.currentVersion = currentVersion
    }

    func start() {
        guard timer == nil else { return }
        // A little after launch, so the welcome banner and agents get the island first.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.check()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func check() {
        guard timer != nil else { return }
        var request = URLRequest(url: Self.latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            guard let data, error == nil, let release = Self.parse(data) else { return }
            Task { @MainActor in self?.handle(release) }
        }.resume()
    }

    private func handle(_ release: Release) {
        guard Self.isNewer(release.version, than: currentVersion),
              UserDefaults.standard.string(forKey: Self.announcedKey) != release.version else { return }
        UserDefaults.standard.set(release.version, forKey: Self.announcedKey)
        coveLog.info("Update available: \(release.version, privacy: .public)")
        onNewRelease?(release)
    }

    /// The release's version (tag without a leading "v") and page, from GitHub's latest-release JSON.
    nonisolated static func parse(_ data: Data) -> Release? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        if json["draft"] as? Bool == true || json["prerelease"] as? Bool == true { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return Release(version: version, url: page)
    }

    /// Numeric comparison of dotted versions ("1.0.10" is newer than "1.0.9"). Non-numeric current
    /// versions (a "dev" build) never count as outdated.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let p = v.split(separator: ".").map { Int($0) }
            return p.isEmpty || p.contains(nil) ? nil : p.compactMap { $0 }
        }
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
