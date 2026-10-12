import Foundation

/// Watches for new screenshots using Spotlight's `kMDItemIsScreenCapture` flag, so it works
/// wherever your screenshots are saved and whatever language the file names are in.
final class ScreenshotWatcher {
    var onNew: (@MainActor ([URL]) -> Void)?

    private let query = NSMetadataQuery()
    private let startedAt = Date()
    private var seen = Set<String>()
    private var observers: [NSObjectProtocol] = []

    /// Must be called on the main thread (NSMetadataQuery delivers on the run loop it started on).
    func start() {
        query.predicate = NSPredicate(
            format: "kMDItemIsScreenCapture == 1 AND kMDItemFSCreationDate >= %@",
            startedAt as NSDate
        )
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            self?.collect(emit: false)
        })
        observers.append(center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
            self?.collect(emit: true)
        })
        query.start()
    }

    func stop() {
        query.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    private func collect(emit: Bool) {
        query.disableUpdates()
        defer { query.enableUpdates() }
        var fresh: [URL] = []
        for case let item as NSMetadataItem in query.results {
            guard let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            if seen.insert(path).inserted, FileManager.default.fileExists(atPath: path) {
                fresh.append(URL(fileURLWithPath: path))
            }
        }
        guard emit, !fresh.isEmpty else { return }
        let callback = onNew
        Task { @MainActor in callback?(fresh) }
    }
}
