import AppKit
import XCTest
@testable import Cove

final class ShelfPersistenceTests: XCTestCase {
    var root: URL!
    var defaults: UserDefaults!
    var suite: String!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "CoveShelfTests.\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }
    func store() -> ShelfStore { ShelfStore(defaults: defaults, root: root.appendingPathComponent("retained")) }
    func image(_ name: String = "Screenshot.png") throws -> URL {
        let url = root.appendingPathComponent(name)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }
    func testImagesSurviveSourceDeletionAndRestart() throws {
        let original = try image(); let shelf = store(); shelf.add([original], atFront: true)
        let saved = try XCTUnwrap(shelf.urls.first)
        XCTAssertNotEqual(saved, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        let bytes = try Data(contentsOf: original)
        try FileManager.default.removeItem(at: original)
        XCTAssertEqual(store().urls, [saved])
        XCTAssertEqual(try Data(contentsOf: saved), bytes)
    }
    func testFortyItemsAreRetainedAcrossRestart() {
        let urls = (0..<40).map { root.appendingPathComponent("file-\($0).txt") }
        let shelf = store(); shelf.add(urls, atFront: false)
        XCTAssertEqual(shelf.urls, urls)
        XCTAssertEqual(store().urls, urls)
    }
    func testDuplicateSourceAndRetainedURLDoNotDuplicate() throws {
        let original = try image(); let shelf = store(); shelf.add([original, original], atFront: true)
        shelf.add(shelf.urls + [original], atFront: true)
        XCTAssertEqual(shelf.urls.count, 1)
        let restored = store(); restored.add([original], atFront: false)
        XCTAssertEqual(restored.urls.count, 1)
    }
    func testRemoveDeletesOnlyOwnedCopy() throws {
        let original = try image(); let shelf = store(); shelf.add([original], atFront: true)
        let saved = shelf.urls[0]; shelf.remove(saved)
        XCTAssertTrue(shelf.urls.isEmpty)
        XCTAssertTrue(store().urls.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testClearLeavesOriginalFilesUntouched() throws {
        let original = try image(); let document = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: document)
        let shelf = store(); shelf.add([original, document], atFront: false); shelf.clear()
        XCTAssertTrue(store().urls.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: document.path))
    }
    func testLegacyMigrationRetainsMissingEntriesAndCopiesImages() throws {
        let original = try image(); let missing = root.appendingPathComponent("cloud-file.txt")
        defaults.set([original.path, missing.path], forKey: "shelf")
        let migrated = store()
        XCTAssertEqual(migrated.urls.count, 2)
        XCTAssertNotEqual(migrated.urls[0], original)
        XCTAssertEqual(migrated.urls[1], missing)
        try FileManager.default.removeItem(at: original)
        XCTAssertNotNil(NSImage(contentsOf: store().urls[0]))
    }
    func testCopyFailureKeepsReference() throws {
        let original = try image()
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: blocked)
        let shelf = ShelfStore(defaults: defaults, root: blocked); shelf.add([original], atFront: false)
        XCTAssertEqual(shelf.urls, [original])
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testCaptureMustBeCompleteBeforeDelivery() throws {
        let original = try image()
        XCTAssertTrue(ScreenshotWatcher.isCaptureFileReady(original))
        let bytes = try Data(contentsOf: original)
        try bytes.prefix(16).write(to: original)
        XCTAssertFalse(ScreenshotWatcher.isCaptureFileReady(original))
        try bytes.write(to: original)
        XCTAssertTrue(ScreenshotWatcher.isCaptureFileReady(original))
    }
    @MainActor func testQuietScreenshotPersistenceAndCompactGeometry() throws {
        var config = CoveConfig(); config.calendar = false; config.sounds = false
        let model = IslandModel(config: config, shelfStore: store())
        model.tab = .sports; model.addScreenshots([try image()])
        XCTAssertNil(model.banner); XCTAssertEqual(model.tab, .sports)
        XCTAssertEqual(model.size(for: .expanded).width, 660)
        model.tab = .home
        XCTAssertEqual(model.size(for: .expanded).width, 500)
        let restored = IslandModel(config: config, shelfStore: store())
        XCTAssertEqual(restored.shelf, model.shelf)
    }
    func testParsedTeamsKeepLeagueForBundledLogoLookup() throws {
        let root: [String: Any] = ["events": [["id":"1", "competitions": [["competitors": [
            ["homeAway":"home", "team":["id":"1", "displayName":"Atlanta Hawks"]],
            ["homeAway":"away", "team":["id":"14", "displayName":"Miami Heat"]]
        ]]]]]]
        let games = try SportsParser.scoreboard(JSONSerialization.data(withJSONObject: root), league: .nba)
        XCTAssertEqual(games[0].home.league, .nba)
        XCTAssertEqual(games[0].away.league, .nba)
    }
}
