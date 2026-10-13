import CoreServices
import Foundation
import os

/// Puts new screenshots on the shelf the moment macOS saves them.
///
/// Detection, fastest first, sharing one de-duplication set:
/// 1. FSEvents on the folder macOS saves screenshots to (Desktop unless changed in the Screenshot app's
///    Options). New image files are checked for the extended attribute macOS adds to every screenshot,
///    with the "Screenshot …" file name as a fallback. Fires within ~0.3 s of the file appearing.
/// 2. A Spotlight query for `kMDItemIsScreenCapture`, for screenshots saved somewhere else.
///
/// The save folder is re-checked every 20 s, so changing it in ⌘⇧5 → Options just works.
///
/// Note: with the floating thumbnail on (the default), macOS only writes the file after the thumbnail
/// slides away (~5 s). `ScreenshotWatcher.setFloatingThumbnail(false)` makes screenshots instant.
final class ScreenshotWatcher {
    enum AccessState: Equatable { case unknown, ok, denied }

    var onNew: (@MainActor ([URL]) -> Void)?
    var onAccess: (@MainActor (AccessState, URL) -> Void)?

    private let log = Logger(subsystem: "app.cove.island", category: "screenshots")
    private let startedAt = Date()
    private var delivered = Set<String>()
    private var stream: FSEventStreamRef?
    private var folder: URL?
    private var recheckTimer: Timer?
    private let query = NSMetadataQuery()
    private var observers: [NSObjectProtocol] = []
    private(set) var access: AccessState = .unknown

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "tif", "gif", "pdf", "mov"]

    deinit { stop() }

    // MARK: Settings macOS keeps for screenshots

    /// Where macOS currently saves screenshots.
    static var screenshotFolder: URL {
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        if let location = CFPreferencesCopyAppValue("location" as CFString, "com.apple.screencapture" as CFString) as? String,
           !location.isEmpty {
            return URL(fileURLWithPath: (location as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Whether macOS shows the floating thumbnail (which delays saving the file by ~5 s).
    static var floatingThumbnail: Bool {
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
        return (CFPreferencesCopyAppValue("show-thumbnail" as CFString, "com.apple.screencapture" as CFString) as? Bool) ?? true
    }

    static func setFloatingThumbnail(_ on: Bool) {
        CFPreferencesSetAppValue("show-thumbnail" as CFString, on as CFBoolean, "com.apple.screencapture" as CFString)
        CFPreferencesAppSynchronize("com.apple.screencapture" as CFString)
    }

    // MARK: Lifecycle (main thread)

    func start() {
        watch(Self.screenshotFolder)
        startSpotlight()
        recheckTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            let current = Self.screenshotFolder
            if current.standardizedFileURL != self.folder?.standardizedFileURL {
                self.log.info("Screenshot folder changed to \(current.path, privacy: .public)")
                self.watch(current)
            }
        }
    }

    func stop() {
        recheckTimer?.invalidate()
        recheckTimer = nil
        stopStream()
        query.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    /// Re-checks folder access (after the user grants it in System Settings).
    func recheckAccess() {
        if let folder { checkAccess(folder) }
    }

    // MARK: FSEvents

    private func watch(_ folder: URL) {
        stopStream()
        self.folder = folder
        checkAccess(folder)

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<ScreenshotWatcher>.fromOpaque(info).takeUnretainedValue()
            // With kFSEventStreamCreateFlagUseCFTypes, `paths` is a CFArray of CFStrings.
            guard let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] else { return }
            var candidates: [URL] = []
            for index in 0..<count {
                let flag = Int(flags[index])
                let isFile = flag & kFSEventStreamEventFlagItemIsFile != 0
                let added = flag & (kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRenamed) != 0
                if isFile && added && index < list.count { candidates.append(URL(fileURLWithPath: list[index])) }
            }
            watcher.consider(candidates)
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.2, flags
        ) else {
            log.error("Couldn't create FSEvents stream for \(folder.path, privacy: .public)")
            return
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
        log.info("Watching \(folder.path, privacy: .public) for screenshots")
    }

    private func stopStream() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Reading the folder triggers macOS's "Cove would like to access your Desktop" prompt the first time.
    private func checkAccess(_ folder: URL) {
        let state: AccessState
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            state = .ok
        } catch let error as NSError {
            let posix = (error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
            state = (error.code == NSFileReadNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES)) ? .denied : .unknown
            log.error("Can't read screenshot folder: \(error.localizedDescription, privacy: .public)")
        }
        access = state
        let callback = onAccess
        Task { @MainActor in callback?(state, folder) }
    }

    /// Called on the main queue by FSEvents. The file may still be settling, so check twice.
    private func consider(_ urls: [URL]) {
        let fresh = urls.filter { url in
            !url.lastPathComponent.hasPrefix(".")
                && Self.imageExtensions.contains(url.pathExtension.lowercased())
                && FileManager.default.fileExists(atPath: url.path)
        }
        guard !fresh.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let shots = fresh.filter { url in
                FileManager.default.fileExists(atPath: url.path) && Self.isScreenshot(url) && self.isNew(url)
            }
            self.deliver(shots)
        }
    }

    private func isNew(_ url: URL) -> Bool {
        let created = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        return created >= startedAt.addingTimeInterval(-2)
    }

    /// Screenshots carry an extended attribute; their default names start with "Screenshot".
    static func isScreenshot(_ url: URL) -> Bool {
        guard imageExtensions.contains(url.pathExtension.lowercased()) else { return false }
        if getxattr(url.path, "com.apple.metadata:kMDItemIsScreenCapture", nil, 0, 0, 0) > 0 { return true }
        return looksLikeScreenshotName(url.lastPathComponent)
    }

    static func looksLikeScreenshotName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return ["screenshot", "screen shot", "screen recording", "cleanshot", "bildschirmfoto", "captura de pantalla", "capture d’écran", "capture d'écran"]
            .contains { lower.hasPrefix($0) }
    }

    // MARK: Spotlight backup

    private func startSpotlight() {
        query.predicate = NSPredicate(format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@", startedAt as NSDate)
        // Only where screenshots normally land, so captures made by other tools elsewhere aren't picked up.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let scopes = [Self.screenshotFolder, home.appendingPathComponent("Desktop"),
                      home.appendingPathComponent("Pictures/Screenshots"), home.appendingPathComponent("Downloads")]
        query.searchScopes = Array(Set(scopes.map(\.standardizedFileURL))).filter { FileManager.default.fileExists(atPath: $0.path) }
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSMetadataQueryDidUpdate, object: query, queue: .main
        ) { [weak self] _ in
            self?.collectSpotlight()
        })
        query.start()
    }

    private func collectSpotlight() {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var found: [URL] = []
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                  FileManager.default.fileExists(atPath: path) else { continue }
            found.append(URL(fileURLWithPath: path))
        }
        deliver(found)
    }

    // MARK: Delivery

    private func deliver(_ urls: [URL]) {
        let new = urls.filter { delivered.insert($0.standardizedFileURL.path).inserted }
        guard !new.isEmpty else { return }
        log.info("New screenshot(s): \(new.map(\.lastPathComponent).joined(separator: ", "), privacy: .public)")
        let callback = onNew
        Task { @MainActor in callback?(new) }
    }
}

extension ScreenshotWatcher: @unchecked Sendable {}
