import AppKit
import XCTest
@testable import Cove

@MainActor final class NewFeatureTests: XCTestCase {
    private func game(_ id: String, league: SportsLeague = .nba, team: String = "14", state: String = "pre", score: String = "0", start: Date = .now) -> SportsGame {
        SportsGame(id: id, league: league, start: start,
                   away: SportsTeam(name: "Away", abbreviation: "AWY", score: score, rank: nil, id: team, league: league),
                   home: SportsTeam(name: "Home", abbreviation: "HME", score: "0", rank: nil, id: "2", league: league),
                   state: state, status: state)
    }
    func testFavoriteSettingsRoundTripAndQuietDefaults() throws {
        let old = try JSONDecoder().decode(CoveConfig.self, from: Data("{}".utf8))
        XCTAssertTrue(old.sportsAutoFollow); XCTAssertFalse(old.sportsStartAlerts); XCTAssertFalse(old.sportsScoreAlerts)
        var config = old; config.sportsFavoriteTeams = ["nba:14", "nfl:2", "nba:14"]
        config.sportsWatchedGames = ["nba:123", "nfl:456"]
        let restored = try JSONDecoder().decode(CoveConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.sportsFavoriteTeams, ["nba:14", "nfl:2"])
        XCTAssertEqual(restored.sportsWatchedGames, config.sportsWatchedGames)
    }
    func testAutoFollowPrefersLiveFavoriteAndHoldsActiveSelection() {
        var config = CoveConfig(); config.sportsFavoriteTeams = ["nba:14"]
        let future = game("1", start: .now.addingTimeInterval(100))
        let live = game("2", state: "in")
        let unrelated = game("3", team: "8", state: "in")
        XCTAssertEqual(SportsFollowRules.automaticGame([future, unrelated, live], current: nil, config: config)?.id, "2")
        XCTAssertNil(SportsFollowRules.automaticGame([future, live], current: unrelated, config: config))
        XCTAssertEqual(SportsFollowRules.automaticGame([future, live], current: game("old", state: "post"), config: config)?.id, "2")
        config.sportsAutoFollow = false
        XCTAssertNil(SportsFollowRules.automaticGame([live], current: nil, config: config))
    }
    func testButtonLookDefaultsToGlassAndRoundTrips() throws {
        XCTAssertEqual(try JSONDecoder().decode(CoveConfig.self, from: Data("{}".utf8)).buttonLook, .glass)
        var config = CoveConfig(); config.buttonLook = .glow
        let restored = try JSONDecoder().decode(CoveConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.buttonLook, .glow)
    }
    func testFinishedWatchedGamesAreDropped() {
        var config = CoveConfig(); config.sportsWatchedGames = ["nba:1", "nba:2", "nba:3"]
        let games = [game("1", state: "post"), game("2", state: "in"), game("4", state: "post")]
        XCTAssertEqual(SportsFollowRules.finishedWatchedGames(games, config: config), ["nba:1"])
    }
    func testGameKeysDoNotCollideAcrossLeagues() {
        XCTAssertNotEqual(game("123").key, game("123", league: .nfl).key)
        var config = CoveConfig(); config.sportsFavoriteTeams = ["nba:14"]
        XCTAssertTrue(game("1").isFavorite(in: config)); XCTAssertFalse(game("1", league: .nfl).isFavorite(in: config))
        config.sportsWatchedGames = ["nfl:1"]
        XCTAssertTrue(game("1", league: .nfl).isFollowed(in: config))
    }
    func testAlertsHaveBaselineAndDoNotRepeatOrFireOnCorrections() {
        var config = CoveConfig(); config.sportsFavoriteTeams = ["nba:14"]; config.sportsStartAlerts = true; config.sportsScoreAlerts = true
        var tracker = SportsAlertTracker()
        XCTAssertTrue(tracker.consume([game("1")], config: config).isEmpty)
        XCTAssertEqual(tracker.consume([game("1", state: "in")], config: config).count, 1)
        XCTAssertEqual(tracker.consume([game("1", state: "in", score: "2")], config: config).count, 1)
        XCTAssertTrue(tracker.consume([game("1", state: "in", score: "2")], config: config).isEmpty)
        XCTAssertTrue(tracker.consume([game("1", state: "in", score: "1")], config: config).isEmpty)
        XCTAssertTrue(tracker.consume([game("other", team: "8", state: "in", score: "20")], config: config).isEmpty)
    }
    func testPinSurvivesMouseExitAndMenusThenExplicitClose() async throws {
        var config = CoveConfig(); config.calendar = false; config.sounds = false
        let model = IslandModel(config: config)
        model.setExpanded(true); model.setHovering(true); model.togglePinnedOpen(); model.setHovering(false)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(model.expanded); XCTAssertTrue(model.isPinnedOpen)
        model.setMenuTracking(true); model.togglePinnedOpen()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(model.expanded)
        model.setMenuTracking(false)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertFalse(model.expanded)
        model.togglePinnedOpen(); model.setExpanded(false)
        XCTAssertFalse(model.isPinnedOpen); XCTAssertFalse(model.expanded)
    }
    func testClickNavigationStaysOpenUntilExplicitClose() async throws {
        var config = CoveConfig(); config.calendar = false; config.sounds = false
        let model = IslandModel(config: config)
        model.setHovering(true)
        model.navigate(to: .ai)
        model.setHovering(false)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertTrue(model.expanded); XCTAssertTrue(model.isPinnedOpen)
        XCTAssertEqual(model.tab, .ai)
        model.setExpanded(false)
        XCTAssertFalse(model.isPinnedOpen); XCTAssertFalse(model.expanded)
    }
    func testLegacyAIHomePreferenceOpensDedicatedAITab() {
        var config = CoveConfig(); config.calendar = false; config.homeWidget = .ai
        let model = IslandModel(config: config)
        XCTAssertEqual(model.tab, .ai)
        XCTAssertEqual(model.config.homeWidget, .sports)
    }
    func testUndoRemovalAndClearSurviveStoreRestart() throws {
        let suite = "CoveUndoTest.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("shot.png")
        let image = try bitmap(); try image.representation(using: .png, properties: [:])!.write(to: original)
        let folder = root.appendingPathComponent("shelf")
        let store = ShelfStore(defaults: defaults, root: folder); store.add([original], atFront: true)
        let saved = store.urls[0]; store.remove(saved)
        XCTAssertTrue(store.canUndo); XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path))
        let restored = ShelfStore(defaults: defaults, root: folder); restored.undo()
        XCTAssertEqual(restored.urls, [saved]); XCTAssertNotNil(NSImage(contentsOf: saved)); XCTAssertFalse(restored.canUndo)
        restored.clear(); restored.undo()
        XCTAssertEqual(restored.urls, [saved]); XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
    func testRenameAndAnnotatedCopyPreserveOriginal() throws {
        let suite = "CoveRenameTest.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("shot.png"), bytes = try bitmap().representation(using: .png, properties: [:])!
        try bytes.write(to: original)
        let folder = root.appendingPathComponent("shelf"), store = ShelfStore(defaults: defaults, root: folder)
        store.add([original], atFront: true)
        XCTAssertThrowsError(try store.rename(store.urls[0], baseName: "../escape"))
        let renamed = try store.rename(store.urls[0], baseName: "My capture")
        XCTAssertEqual(renamed.lastPathComponent, "My capture.png"); XCTAssertEqual(try Data(contentsOf: original), bytes)
        let copy = try store.saveEditedImage(bytes, name: "shot.png")
        XCTAssertTrue(store.urls.contains(copy))
        let restarted = ShelfStore(defaults: defaults, root: folder)
        XCTAssertEqual(restarted.urls, store.urls, "Owned annotated images must not be copied again at restart")
        restarted.clear(); XCTAssertEqual(try Data(contentsOf: original), bytes)
    }
    func testAnnotationRendererChangesMarkedPixelsAndKeepsResolution() throws {
        _ = NSApplication.shared
        let original = try bitmap()
        let image = NSImage(size: NSSize(width: 100, height: 80)); image.addRepresentation(original)
        let data = try ShelfImageRenderer.png(image: image, strokes: [ShelfStroke(points: [CGPoint(x: 0.1,y: 0.5),CGPoint(x: 0.9,y: 0.5)], color: .red, width: 0.05)], labels: [])
        let output = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(output.pixelsWide, 100); XCTAssertEqual(output.pixelsHigh, 80)
        let marked = try XCTUnwrap(output.colorAt(x: 50, y: 40)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(marked.redComponent, 0.8); XCTAssertLessThan(marked.greenComponent, 0.2)
        let untouched = try XCTUnwrap(output.colorAt(x: 2, y: 2)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(untouched.greenComponent, 0.8)
    }
    private func bitmap() throws -> NSBitmapImageRep {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let green = NSColor(deviceRed: 0, green: 1, blue: 0, alpha: 1)
        for y in 0..<80 { for x in 0..<100 { bitmap.setColor(green, atX: x, y: y) } }
        return bitmap
    }
}
