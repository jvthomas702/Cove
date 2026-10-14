import Foundation

/// Shelf membership survives restarts. Images get a private copy; originals remain available to their owner.
final class ShelfStore {
    private struct Entry: Codable {
        var original: String
        var retained: String
        var bookmark: Data?
        var owned: Bool?
    }
    private struct Removed: Codable { var index: Int; var entry: Entry }
    private var removed: [Removed] = []
    var canUndo: Bool { !removed.isEmpty }
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
        if let data = defaults.data(forKey: "shelf.undo.v1"), let items = try? JSONDecoder().decode([Removed].self, from: data) { removed = items }
        // Migrate readable images, but keep unavailable references so a temporary permission or cloud issue cannot erase them.
        for index in entries.indices {
            let entry = entries[index]
            let url = URL(fileURLWithPath: entry.retained)
            if entry.owned != true, entry.original == entry.retained, let saved = retainImage(url) { entries[index].retained = saved.path }
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
        guard !indexes.isEmpty else { return }
        discardUndo()
        for index in indexes.reversed() { removed.insert(Removed(index: index, entry: stash(entries.remove(at: index))), at: 0) }
        save()
    }

    func clear() {
        guard !entries.isEmpty else { return }
        discardUndo()
        removed = entries.enumerated().map { Removed(index: $0.offset, entry: stash($0.element)) }
        entries.removeAll()
        save()
    }

    func undo() {
        for item in removed.sorted(by: { $0.index < $1.index }) {
            var entry = item.entry
            let url = URL(fileURLWithPath: entry.retained)
            let directory = url.deletingLastPathComponent()
            if directory.deletingLastPathComponent().standardizedFileURL == root.appendingPathComponent("Trash").standardizedFileURL {
                let restored = root.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
                do {
                    try FileManager.default.moveItem(at: directory, to: restored)
                    entry.retained = restored.appendingPathComponent(url.lastPathComponent).path
                    entry.bookmark = try? URL(fileURLWithPath: entry.retained).bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                } catch { /* Keep the retained trash copy available if restoring its path fails. */ }
            }
            if !entries.contains(where: { $0.original == entry.original }) { entries.insert(entry, at: min(item.index, entries.count)) }
        }
        removed = []; save()
    }

    func rename(_ url: URL, baseName: String) throws -> URL {
        guard let index = urls.firstIndex(of: url), owns(entries[index]) else { throw ShelfError.notSavedImage }
        let name = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 200,
              !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ShelfError.invalidName }
        let target = url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(url.pathExtension)
        if target == url { return url }
        try FileManager.default.moveItem(at: url, to: target)
        entries[index].retained = target.path
        entries[index].bookmark = try? target.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        save(); return target
    }

    func saveEditedImage(_ data: Data, name: String) throws -> URL {
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeName = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent + " annotated.png"
        let url = directory.appendingPathComponent(safeName)
        do { try data.write(to: url, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: directory); throw error }
        entries.insert(Entry(original: url.path, retained: url.path, bookmark: try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), owned: true), at: 0)
        save(); return url
    }

    enum ShelfError: LocalizedError {
        case notSavedImage, invalidName
        var errorDescription: String? {
            switch self {
            case .notSavedImage: return "This item is a file reference. Rename it in Finder."
            case .invalidName: return "Choose a name without slashes or control characters."
            }
        }
    }

    private func owns(_ entry: Entry) -> Bool {
        let directory = URL(fileURLWithPath: entry.retained).deletingLastPathComponent()
        let parent = directory.deletingLastPathComponent().standardizedFileURL
        return (entry.original != entry.retained || entry.owned == true) && UUID(uuidString: directory.lastPathComponent) != nil
            && (parent == root.standardizedFileURL || parent == root.appendingPathComponent("Trash").standardizedFileURL)
    }

    private func stash(_ entry: Entry) -> Entry {
        guard owns(entry) else { return entry }
        var item = entry
        let url = URL(fileURLWithPath: entry.retained)
        let directory = url.deletingLastPathComponent()
        let trash = root.appendingPathComponent("Trash", isDirectory: true)
        let target = trash.appendingPathComponent(directory.lastPathComponent, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: directory, to: target)
            item.retained = target.appendingPathComponent(url.lastPathComponent).path
            item.bookmark = nil
        } catch { /* Keep the saved bytes until Undo is used or superseded. */ }
        return item
    }

    private func discardUndo() { removed.forEach { deleteCopy($0.entry) }; removed = [] }

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
        guard owns(entry) else { return }
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: entry.retained).deletingLastPathComponent())
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
        defaults.set(entries.map(\.retained), forKey: "shelf")
        if let data = try? JSONEncoder().encode(removed) { defaults.set(data, forKey: "shelf.undo.v1") }
    }
}
