import AppKit
import Combine

/// One file or folder in the browser.
struct FileEntry: Identifiable, Hashable {
    let url: URL
    let isFolder: Bool
    let size: Int64?
    let modified: Date?

    var id: URL { url }
    var name: String { url.lastPathComponent }
    var kind: FileKind { isFolder ? .other : FileKind.of(url) }
}

/// A shortcut in the browser's sidebar strip.
struct FilePlace: Identifiable, Hashable {
    let name: String
    let symbol: String
    let url: URL
    var id: URL { url }
}

/// Browses folders on your Mac from the island's Files tab, and finds files by name with Spotlight.
@MainActor final class FileBrowser: ObservableObject {
    enum Sort: String, CaseIterable { case name = "Name", recent = "Date" }

    @Published private(set) var folder: URL
    @Published private(set) var entries: [FileEntry] = []
    @Published private(set) var error: String?
    @Published private(set) var loading = false
    @Published var selection: Set<URL> = []
    @Published var sort: Sort = .name { didSet { entries = Self.sorted(entries, by: sort) } }
    @Published var showHidden = false { didSet { reload() } }
    /// Filters the folder as you type; two letters or more also searches the whole Mac.
    @Published var query = "" { didSet { searchSoon() } }
    @Published private(set) var searchResults: [URL] = []
    @Published private(set) var searching = false
    private var back: [URL] = []
    private var searchTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// Runs Spotlight (`mdfind`); replaced in tests.
    var spotlight: (String, URL) async -> [URL] = FileBrowser.mdfind

    let places: [FilePlace]

    init(start: URL? = nil) {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var places = [FilePlace(name: "Home", symbol: "house", url: home)]
        let standard: [(String, String, FileManager.SearchPathDirectory)] = [
            ("Desktop", "menubar.dock.rectangle", .desktopDirectory),
            ("Documents", "doc", .documentDirectory),
            ("Downloads", "arrow.down.circle", .downloadsDirectory),
        ]
        for (name, symbol, directory) in standard {
            if let url = fm.urls(for: directory, in: .userDomainMask).first { places.append(FilePlace(name: name, symbol: symbol, url: url)) }
        }
        let iCloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        if fm.fileExists(atPath: iCloud.path) { places.append(FilePlace(name: "iCloud Drive", symbol: "icloud", url: iCloud)) }
        places.append(FilePlace(name: "Applications", symbol: "square.grid.2x2", url: URL(fileURLWithPath: "/Applications")))
        self.places = places
        folder = start ?? fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? home
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoUp: Bool { folder.path != "/" }
    var isSearching: Bool { query.trimmingCharacters(in: .whitespaces).count >= 2 }

    /// Entries in this folder whose name contains the query.
    var visibleEntries: [FileEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    /// Folder names from the top down, for the path bar: Home › Documents › Classes.
    var crumbs: [URL] {
        var list: [URL] = []
        var url = folder.standardizedFileURL
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        while true {
            list.insert(url, at: 0)
            if url == home || url.path == "/" { break }
            url = url.deletingLastPathComponent().standardizedFileURL
        }
        return list
    }

    func displayName(_ url: URL) -> String {
        if url.standardizedFileURL == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL { return "Home" }
        if url.path == "/" { return "Mac" }
        return FileManager.default.displayName(atPath: url.path)
    }

    /// Selected files in the order they're listed, or `fallback` when nothing is selected.
    func selectedURLs(or fallback: URL? = nil) -> [URL] {
        let listed = (visibleEntries.map(\.url) + searchResults).filter { selection.contains($0) }
        if !listed.isEmpty { return listed }
        return fallback.map { [$0] } ?? []
    }

    func go(to url: URL, remember: Bool = true) {
        guard url.standardizedFileURL != folder.standardizedFileURL else { reload(); return }
        if remember { back.append(folder); if back.count > 30 { back.removeFirst() } }
        folder = url
        selection = []
        query = ""
        reload()
    }

    func goBack() {
        guard let previous = back.popLast() else { return }
        go(to: previous, remember: false)
    }

    func goUp() { if canGoUp { go(to: folder.deletingLastPathComponent()) } }

    /// Folders open in place; files open in their default app.
    func open(_ url: URL) {
        if Self.isBrowsableFolder(url) { go(to: url) } else { NSWorkspace.shared.open(url) }
    }

    func toggleSelection(_ url: URL, extend: Bool) {
        if extend {
            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
        } else {
            selection = selection == [url] ? [] : [url]
        }
    }

    func reload() {
        let folder = self.folder, hidden = showHidden, sort = self.sort
        loading = true
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { Self.list(folder, showHidden: hidden) }.value
            guard let self, !Task.isCancelled, self.folder == folder else { return }
            self.loading = false
            switch result {
            case .success(let entries):
                self.entries = Self.sorted(entries, by: sort)
                self.error = nil
            case .failure(let error):
                self.entries = []
                self.error = error.localizedDescription
            }
        }
    }

    private func searchSoon() {
        searchTask?.cancel()
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { searchResults = []; searching = false; return }
        searching = true
        let scope = FileManager.default.homeDirectoryForCurrentUser
        let run = spotlight
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let found = await run(q, scope)
            guard let self, !Task.isCancelled else { return }
            let here = Set(self.entries.map(\.url.standardizedFileURL))
            self.searchResults = found.filter { !here.contains($0.standardizedFileURL) }
            self.searching = false
        }
    }

    // MARK: - Listing

    enum ListError: LocalizedError {
        case noAccess(String), missing(String)
        var errorDescription: String? {
            switch self {
            case .noAccess(let name): return "Cove can’t open \(name). Allow it in System Settings → Privacy & Security → Files and Folders."
            case .missing(let name): return "\(name) isn’t there any more."
            }
        }
    }

    nonisolated static func isBrowsableFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    nonisolated static func list(_ folder: URL, showHidden: Bool) -> Result<[FileEntry], Error> {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]
        do {
            let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                                   options: showHidden ? [] : [.skipsHiddenFiles])
            return .success(urls.map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let folder = values?.isDirectory == true && values?.isPackage != true
                return FileEntry(url: url, isFolder: folder, size: folder ? nil : values?.fileSize.map { Int64($0) },
                                 modified: values?.contentModificationDate)
            })
        } catch let error as CocoaError where error.code == .fileReadNoPermission {
            return .failure(ListError.noAccess(folder.lastPathComponent))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .failure(ListError.missing(folder.lastPathComponent))
        } catch {
            return .failure(error)
        }
    }

    /// Folders first, then by name (Finder's order) or newest first.
    nonisolated static func sorted(_ entries: [FileEntry], by sort: Sort) -> [FileEntry] {
        entries.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            switch sort {
            case .name: return a.name.localizedStandardCompare(b.name) == .orderedAscending
            case .recent: return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
            }
        }
    }

    /// Spotlight name search under `scope`, at most 40 results. The query is passed as one argument, never through a shell.
    nonisolated static func mdfind(_ query: String, scope: URL) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["-onlyin", scope.path, "-name", query]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let library = scope.appendingPathComponent("Library").path + "/"
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.hasPrefix(library) && !$0.split(separator: "/").contains { $0.hasPrefix(".") } }
                .prefix(40)
                .map { URL(fileURLWithPath: $0) }
        }.value
    }
}
