import Foundation

/// Shelf membership survives restarts. Images get a private copy; originals remain available to their owner.
final class ShelfStore {
    private struct Entry: Codable {
        var original: String
        var retained: String
        var bookmark: Data?
    }
    let root: URL
    private let defaults: UserDefaults
    private var entries: [Entry]
    private static let key = "shelf.records.v1"
    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp"]

    init(defaults: UserDefaults = .standard, root: URL? = nil) {
        self.defaults = defaults
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName, isDirectory: true)
            .appendingPathComponent("Shelf", isDirectory: true)
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        } else {
            entries = (defaults.stringArray(forKey: "shelf") ?? []).map { Entry(original: $0, retained: $0) }
        }
        // Migrate readable images, but keep unavailable references so a temporary permission or cloud issue cannot erase them.
        for index in entries.indices {
            let entry = entries[index]
            let url = URL(fileURLWithPath: entry.retained)
            if entry.original == entry.retained, let saved = retainImage(url) { entries[index].retained = saved.path }
            if entries[index].bookmark == nil {
                entries[index].bookmark = try? URL(fileURLWithPath: entries[index].retained).bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            }
        }
        save()
    }

    var urls: [URL] {
        entries.map { entry in
            let saved = URL(fileURLWithPath: entry.retained)
            if FileManager.default.fileExists(atPath: saved.path) { return saved }
            if let bookmark = entry.bookmark {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale),
                   FileManager.default.fileExists(atPath: resolved.path) { return resolved }
            }
            return saved
        }
    }

    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return entries.contains { $0.original == path || $0.retained == path } || urls.contains(url)
    }

    func add(_ urls: [URL], atFront: Bool) {
        for url in urls where url.isFileURL && !contains(url) {
            let saved = retainImage(url) ?? url
            let bookmark = try? saved.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            let entry = Entry(original: url.standardizedFileURL.path, retained: saved.path, bookmark: bookmark)
            if atFront { entries.insert(entry, at: 0) } else { entries.append(entry) }
        }
        save()
    }

    func remove(_ url: URL) {
        let resolved = urls
        let indexes = entries.indices.filter { entries[$0].retained == url.path || entries[$0].original == url.path || resolved[$0] == url }
        for index in indexes.reversed() { deleteCopy(entries.remove(at: index)) }
        save()
    }

    func clear() {
        entries.forEach(deleteCopy)
        entries.removeAll()
        save()
    }

    private func retainImage(_ url: URL) -> URL? {
        guard Self.imageExtensions.contains(url.pathExtension.lowercased()),
              FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let target = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: target)
            return target
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return nil
        }
    }

    private func deleteCopy(_ entry: Entry) {
        let url = URL(fileURLWithPath: entry.retained)
        let directory = url.deletingLastPathComponent()
        // Never remove the original or any file outside a directory this store owns.
        guard entry.retained != entry.original, directory.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              UUID(uuidString: directory.lastPathComponent) != nil else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
        defaults.set(entries.map(\.retained), forKey: "shelf")
    }
}
