import Foundation

/// Puts new screenshots on the shelf.
///
/// Two detectors run side by side and share one de-duplication set:
/// 1. A file-system watch on the folder macOS saves screenshots to (Desktop unless you changed it in
///    the Screenshot app's Options). New image files are checked for the extended attribute macOS adds
///    to every screenshot, with the default "Screenshot …" file name as a fallback. This fires within
///    a second of the file being written.
/// 2. A Spotlight query for `kMDItemIsScreenCapture`, which catches screenshots saved elsewhere once
///    Spotlight has indexed them.
final class ScreenshotWatcher {
    var onNew: (@MainActor ([URL]) -> Void)?

    private let startedAt = Date()
    private var delivered = Set<String>()
    private var known = Set<String>()

    // Folder watch
    private var folder: URL?
    private var source: DispatchSourceFileSystemObject?
    private var pendingScan: DispatchWorkItem?

    // Spotlight backup
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "pdf"]

    /// Where macOS currently saves screenshots.
    static var screenshotFolder: URL {
        if let location = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
           !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Call on the main thread.
    func start() {
        watchFolder()
        startSpotlight()
    }

    func stop() {
        source?.cancel()
        source = nil
        query.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: Folder watch

    private func watchFolder() {
        let folder = Self.screenshotFolder
        self.folder = folder
        // Remember what's already there so only new files count.
        known = Set(contents(of: folder).map(\.path))

        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else {
            NSLog("Cove: can't watch \(folder.path) for screenshots (errno \(errno)); relying on Spotlight")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .extend], queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleScan() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// macOS writes a hidden temp file and renames it; wait a moment so the final file is in place.
    private func scheduleScan() {
        pendingScan?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.scanFolder() }
        pendingScan = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func scanFolder() {
        guard let folder else { return }
        var fresh: [URL] = []
        for url in contents(of: folder) where !known.contains(url.path) {
            known.insert(url.path)
            let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
            guard created >= startedAt.addingTimeInterval(-2), Self.isScreenshot(url) else { continue }
            fresh.append(url)
        }
        deliver(fresh)
    }

    private func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
    }

    static func isScreenshot(_ url: URL) -> Bool {
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        // macOS tags every screenshot with this extended attribute, whatever it's named.
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 { return true }
        let name = url.lastPathComponent.lowercased()
        return name.hasPrefix("screenshot") || name.hasPrefix("screen shot") || name.hasPrefix("cleanshot")
    }

    // MARK: Spotlight backup

    private func startSpotlight() {
        query.predicate = NSPredicate(
            format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@",
            startedAt as NSDate
        )
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
            self?.collectSpotlight()
        })
        query.start()
    }

    private func collectSpotlight() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var fresh: [URL] = []
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  FileManager.default.fileExists(atPath: path) else { continue }
            fresh.append(URL(fileURLWithPath: path))
        }
        deliver(fresh)
    }

    // MARK: Delivery

    private func deliver(_ urls: [URL]) {
        let new = urls.filter { delivered.insert($0.standardizedFileURL.path).inserted }
        guard !new.isEmpty else { return }
        let callback = onNew
        Task { @MainActor in callback?(new) }
    }
}
