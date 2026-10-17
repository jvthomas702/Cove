import AppKit
import XCTest
@testable import Cove

@MainActor final class DropRoutingTests: XCTestCase {
    private let frames: [DropTarget: CGRect] = [
        .airDrop: CGRect(x: 14, y: 50, width: 290, height: 110),
        .keep: CGRect(x: 312, y: 50, width: 290, height: 110),
    ]

    func testOnlyFileURLsAreAcceptedOnceEachInOrder() {
        let a = URL(fileURLWithPath: "/tmp/a.pdf")
        let b = URL(fileURLWithPath: "/tmp/folder/../b.png")
        let web = URL(string: "https://example.com/c.zip")!
        let accepted = DropRouting.acceptedFiles([a, web, b, a, URL(fileURLWithPath: "/tmp/b.png")])
        XCTAssertEqual(accepted.map(\.path), ["/tmp/a.pdf", "/tmp/b.png"])
        XCTAssertTrue(DropRouting.acceptedFiles([web]).isEmpty)
        XCTAssertTrue(DropRouting.acceptedFiles([]).isEmpty)
    }

    func testDropLandsOnTheTargetUnderThePointer() {
        XCTAssertEqual(DropRouting.target(at: CGPoint(x: 100, y: 100), in: frames, airDropEnabled: true), .airDrop)
        XCTAssertEqual(DropRouting.target(at: CGPoint(x: 400, y: 100), in: frames, airDropEnabled: true), .keep)
    }

    func testDropOutsideTheTargetsOrBeforeTheyAppearKeepsTheFile() {
        // The header, the gap between tiles, and a compact island that hasn't opened yet.
        XCTAssertEqual(DropRouting.target(at: CGPoint(x: 100, y: 10), in: frames, airDropEnabled: true), .keep)
        XCTAssertEqual(DropRouting.target(at: CGPoint(x: 308, y: 100), in: frames, airDropEnabled: true), .keep)
        XCTAssertEqual(DropRouting.target(at: CGPoint(x: 100, y: 100), in: [:], airDropEnabled: true), .keep)
    }

    func testTurningTheZoneOffAlwaysKeeps() {
        XCTAssertEqual(DropRouting.target(at: CGPoint(x: 100, y: 100), in: frames, airDropEnabled: false), .keep)
    }

    func testSettingDefaultsOnAndRoundTrips() throws {
        let old = try JSONDecoder().decode(CoveConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(old.airDropDropZone)
        var config = old; config.airDropDropZone = false
        XCTAssertFalse(try JSONDecoder().decode(CoveConfig.self, from: JSONEncoder().encode(config)).airDropDropZone)
    }

    func testDragOverOpensTheShelfAndLeavingClearsTheHighlight() {
        let model = IslandModel(config: CoveConfig())
        model.setDropTargeted(true)
        XCTAssertTrue(model.expanded)
        XCTAssertEqual(model.tab, .shelf)
        model.setDropHover(.airDrop)
        XCTAssertEqual(model.dropHover, .airDrop)
        model.setDropTargeted(false)
        XCTAssertNil(model.dropHover)
        XCTAssertFalse(model.isDropTargeted)
    }

    func testDropOnKeepPutsTheFileOnTheShelf() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "CoveDropTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let file = root.appendingPathComponent("notes.txt")
        try Data("notes".utf8).write(to: file)
        let model = IslandModel(config: CoveConfig(), shelfStore: ShelfStore(defaults: defaults, root: root.appendingPathComponent("retained")))
        model.receiveDrop([NSItemProvider(object: file as NSURL), NSItemProvider(object: file as NSURL)], target: .keep)
        for _ in 0..<60 where model.shelf.isEmpty {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(model.shelf.map { $0.resolvingSymlinksInPath().path }, [file.resolvingSymlinksInPath().path])
    }
}
