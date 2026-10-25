import XCTest
@testable import Cove

@MainActor final class FileBrowserTests: XCTestCase {
    /// Two folders, two files and a dot file. Remove it with `defer`.
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cove-browse-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Classes"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("archive"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("b notes.txt"))
        try Data("bb".utf8).write(to: root.appendingPathComponent("A photo.jpg"))
        try Data("x".utf8).write(to: root.appendingPathComponent(".hidden"))
        return root
    }

    private func entry(_ browser: FileBrowser, _ name: String) throws -> URL {
        try XCTUnwrap(browser.entries.first { $0.name == name }?.url)
    }

    private func loaded(_ browser: FileBrowser, at folder: URL) async throws -> [FileEntry] {
        browser.go(to: folder)
        for _ in 0..<100 where browser.loading || browser.folder != folder { try await Task.sleep(nanoseconds: 20_000_000) }
        return browser.entries
    }

    func testListsFoldersFirstInFinderOrderAndHidesDotFiles() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = FileBrowser(start: root.deletingLastPathComponent())
        let entries = try await loaded(browser, at: root)
        XCTAssertEqual(entries.map(\.name), ["archive", "Classes", "A photo.jpg", "b notes.txt"])
        XCTAssertEqual(entries.first?.isFolder, true)
        XCTAssertEqual(entries.first { $0.name == "A photo.jpg" }?.size, 2)

        browser.showHidden = true
        for _ in 0..<100 where browser.loading { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(browser.entries.contains { $0.name == ".hidden" })
    }

    func testFilterSelectionAndHistory() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = FileBrowser(start: root.deletingLastPathComponent())
        _ = try await loaded(browser, at: root)
        browser.spotlight = { _, _ in [] }
        browser.query = "photo"
        XCTAssertEqual(browser.visibleEntries.map(\.name), ["A photo.jpg"])
        browser.query = ""

        let photo = try entry(browser, "A photo.jpg"), notes = try entry(browser, "b notes.txt")
        browser.toggleSelection(notes, extend: false)
        browser.toggleSelection(photo, extend: true)
        XCTAssertEqual(browser.selectedURLs().map(\.lastPathComponent), ["A photo.jpg", "b notes.txt"], "listed order, not click order")
        browser.toggleSelection(notes, extend: false)
        XCTAssertEqual(browser.selection, [notes])

        _ = try await loaded(browser, at: root.appendingPathComponent("Classes"))
        XCTAssertTrue(browser.selection.isEmpty)
        XCTAssertEqual(browser.crumbs.last?.lastPathComponent, "Classes")
        browser.goBack()
        XCTAssertEqual(browser.folder, root)
    }

    func testSpotlightResultsSkipFilesAlreadyListed() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = FileBrowser(start: root.deletingLastPathComponent())
        _ = try await loaded(browser, at: root)
        let elsewhere = URL(fileURLWithPath: "/Users/someone/Documents/photo essay.pages")
        let listed = try entry(browser, "A photo.jpg")
        browser.spotlight = { query, _ in
            XCTAssertEqual(query, "photo")
            return [listed, elsewhere]
        }
        browser.query = "photo"
        XCTAssertTrue(browser.isSearching)
        for _ in 0..<100 where browser.searching { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(browser.searchResults, [elsewhere])
    }

    func testMissingFolderExplainsItself() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let browser = FileBrowser(start: root)
        _ = try await loaded(browser, at: root.appendingPathComponent("gone"))
        XCTAssertEqual(browser.error, "gone isn’t there any more.")
    }

    func testSortByDateKeepsFoldersFirst() {
        let old = FileEntry(url: URL(fileURLWithPath: "/a.txt"), isFolder: false, size: 1, modified: Date(timeIntervalSince1970: 0))
        let new = FileEntry(url: URL(fileURLWithPath: "/b.txt"), isFolder: false, size: 1, modified: Date())
        let folder = FileEntry(url: URL(fileURLWithPath: "/z"), isFolder: true, size: nil, modified: nil)
        XCTAssertEqual(FileBrowser.sorted([old, new, folder], by: .recent).map(\.name), ["z", "b.txt", "a.txt"])
    }
}
