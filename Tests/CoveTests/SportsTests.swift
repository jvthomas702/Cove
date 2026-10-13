import XCTest
@testable import Cove

final class SportsParserTests: XCTestCase {
    func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testNBAPlaysAreNewestFirst() throws {
        let (game, plays) = try SportsParser.summary(fixture("nba-summary"), league: .nba)
        XCTAssertEqual(game?.away.abbreviation, "OKC")
        XCTAssertEqual(game?.home.abbreviation, "ATL")
        XCTAssertEqual(game?.away.score, "110")
        XCTAssertEqual(plays.first?.sequence, 749) // Replay review arrived after the end-of-game row.
        XCTAssertEqual(plays.first?.timeLabel, "Q4 · 0.0")
        XCTAssertEqual(plays.map(\.sequence), plays.map(\.sequence).sorted(by: >))
    }

    func testNFLUsesDrivePlays() throws {
        let (game, plays) = try SportsParser.summary(fixture("nfl-summary"), league: .nfl)
        XCTAssertEqual(game?.home.abbreviation, "DAL")
        XCTAssertEqual(game?.away.score, "24")
        XCTAssertTrue(game?.isFinal == true)
        XCTAssertEqual(plays.first?.text, "END GAME")
        XCTAssertEqual(plays.first?.score, "24–16")
        XCTAssertFalse(plays.isEmpty)
    }

    func testCollegeRankingsExcludeSentinel99() throws {
        let games = try SportsParser.scoreboard(fixture("cfb-scoreboard"), league: .collegeFootball)
        XCTAssertTrue(games.contains(where: { $0.isRanked }))
        XCTAssertTrue(games.contains(where: { !$0.isRanked && $0.home.rank == nil }))
        XCTAssertEqual(games.filter(\.isRanked).count, 1)
    }

    func testScoreboardDatesWithoutSeconds() throws {
        let games = try SportsParser.scoreboard(fixture("nfl-scoreboard"), league: .nfl)
        XCTAssertNotNil(games.first?.start)
    }

    func testEmptySlateAndInvalidResponseDiffer() throws {
        XCTAssertTrue(try SportsParser.scoreboard(Data(#"{"events":[]}"#.utf8), league: .nba).isEmpty)
        XCTAssertThrowsError(try SportsParser.scoreboard(Data(#"{"error":"unavailable"}"#.utf8), league: .nba))
        XCTAssertThrowsError(try SportsParser.summary(Data(#"{}"#.utf8), league: .nfl))
    }

    func testCurrentDriveIsIncludedAndDuplicateIDsAreRemoved() throws {
        var json = try JSONSerialization.jsonObject(with: fixture("nfl-summary")) as! [String: Any]
        var drives = json["drives"] as! [String: Any]
        let previous = drives["previous"] as! [[String: Any]]
        let plays = previous[0]["plays"] as! [[String: Any]]
        drives["current"] = ["plays": plays + [["id": "new", "sequenceNumber": "999999", "text": "New play"]]]
        json["drives"] = drives
        let (_, parsed) = try SportsParser.summary(JSONSerialization.data(withJSONObject: json), league: .nfl)
        XCTAssertEqual(parsed.first?.id, "new")
        XCTAssertEqual(parsed.count, plays.count + 1)
    }

    func testScoringRecapIsNotUsedAsPlayByPlay() throws {
        var json = try JSONSerialization.jsonObject(with: fixture("nfl-summary")) as! [String: Any]
        json["drives"] = nil
        json["scoringPlays"] = [["id": "score", "text": "Touchdown"]]
        XCTAssertTrue(try SportsParser.summary(JSONSerialization.data(withJSONObject: json), league: .nfl).1.isEmpty)
    }

    func testWidgetConfigPersistsAndOldConfigsBecomeQuiet() throws {
        let old = try JSONDecoder().decode(CoveConfig.self, from: Data(#"{"screenshotsToShelf":true}"#.utf8))
        XCTAssertFalse(old.screenshotBanners)
        XCTAssertEqual(old.homeWidget, .auto)
        XCTAssertTrue(old.sportsRankedOnly)
        var config = old
        config.homeWidget = .sports
        config.sportsLeague = .nba
        config.sportsGameID = "chosen"
        let restored = try JSONDecoder().decode(CoveConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(restored.sportsGameID, "chosen")
        XCTAssertEqual(restored.sportsLeague, .nba)
        XCTAssertEqual(restored.homeWidget, .sports)
    }
}

@MainActor
final class QuietScreenshotTests: XCTestCase {
    private func model() -> IslandModel {
        var config = CoveConfig()
        config.calendar = false
        config.sounds = false
        return IslandModel(config: config)
    }

    func testQuietCaptureKeepsSelectedTab() {
        let model = model()
        let originalShelf = model.shelf
        defer { model.clearShelf(); model.addToShelf(originalShelf) }
        model.tab = .sports
        model.addScreenshots([URL(fileURLWithPath: "/tmp/cove-quiet-capture.png")])
        XCTAssertNil(model.banner)
        XCTAssertTrue(model.history.isEmpty)
        model.setExpanded(true)
        XCTAssertEqual(model.tab, .sports)
        model.setExpanded(false)
        XCTAssertEqual(model.tab, .sports)
    }

    func testDuplicateCaptureDoesNotReplayBanner() {
        let model = model()
        let originalShelf = model.shelf
        defer { model.clearShelf(); model.addToShelf(originalShelf) }
        model.config.screenshotBanners = true
        let url = URL(fileURLWithPath: "/tmp/cove-duplicate-capture.png")
        model.removeFromShelf(url)
        model.addScreenshots([url])
        let first = model.banner?.id
        model.addScreenshots([url, url])
        XCTAssertEqual(model.banner?.id, first)
        XCTAssertEqual(model.shelf.filter { $0 == url }.count, 1)
    }

    func testDeniedFolderAccessDoesNotCreateStickyPopup() {
        let model = model()
        model.setScreenshotAccess(.denied, folder: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(model.screenshotAccess, .denied)
        XCTAssertNil(model.banner)
    }

    func testCaptureIdentitySurvivesRenameAndOldFilesAreRejected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("Screenshot 2026-10-13.png")
        let b = directory.appendingPathComponent("Screenshot 2026-10-13 renamed.png")
        try Data([1]).write(to: a)
        let identity = try XCTUnwrap(ScreenshotWatcher.captureIdentity(a))
        XCTAssertTrue(ScreenshotWatcher.isFreshCapture(a, since: Date().addingTimeInterval(-5)))
        XCTAssertFalse(ScreenshotWatcher.isFreshCapture(a, since: Date().addingTimeInterval(5)))
        try FileManager.default.moveItem(at: a, to: b)
        XCTAssertEqual(ScreenshotWatcher.captureIdentity(b), identity)
        XCTAssertFalse(ScreenshotWatcher.isFreshCapture(a, since: .distantPast))
        XCTAssertFalse(ScreenshotWatcher.looksLikeScreenshotName("Screenshot notes.png"))
    }
}

final class TeamColorTests: XCTestCase {
    func testReadsProviderColorsAndRejectsMalformedHex() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "nba-summary", withExtension: "json", subdirectory: "Fixtures"))
        let (game, _) = try SportsParser.summary(Data(contentsOf: url), league: .nba)
        XCTAssertNotNil(game?.away.primaryHex)
        XCTAssertNotNil(game?.home.primaryHex)
        XCTAssertNotEqual(game?.away.primaryHex, game?.home.primaryHex)
        XCTAssertEqual(SportsTeam.colorHex("#006BB6"), 0x006BB6)
        XCTAssertNil(SportsTeam.colorHex("not-a-color"))
        XCTAssertNil(SportsTeam.colorHex("FFF"))
    }

    func testDarkTeamColorsRemainReadableOnBlack() {
        let team = SportsTeam(name: "Test", abbreviation: "TST", score: "0", rank: nil, primaryHex: 0x001122)
        XCTAssertGreaterThanOrEqual(SportsTeam.contrastOnBlack(team.accentHex), 4.5)
        let alternate = SportsTeam(name: "Test", abbreviation: "TST", score: "0", rank: nil, primaryHex: 0x000000, alternateHex: 0xFFFFFF)
        XCTAssertEqual(alternate.accentHex, 0xFFFFFF)
    }
}

final class TeamLogoTests: XCTestCase {
    func testSummaryAndScoreboardLogoShapes() throws {
        let summary = try XCTUnwrap(Bundle.module.url(forResource: "nba-summary", withExtension: "json", subdirectory: "Fixtures"))
        let (game, _) = try SportsParser.summary(Data(contentsOf: summary), league: .nba)
        XCTAssertEqual(game?.home.logoURL?.lastPathComponent, "atl.png")
        let scoreboard = try XCTUnwrap(Bundle.module.url(forResource: "nba-scoreboard", withExtension: "json", subdirectory: "Fixtures"))
        let games = try SportsParser.scoreboard(Data(contentsOf: scoreboard), league: .nba)
        XCTAssertTrue(games.contains { $0.home.logoURL != nil || $0.away.logoURL != nil })
    }
    func testMissingAndInvalidLogosKeepFallback() {
        XCTAssertNil(SportsTeam.logoURL(nil))
        XCTAssertNil(SportsTeam.logoURL("http://a.espncdn.com/a.png"))
        XCTAssertNil(SportsTeam.logoURL("https://espncdn.com.evil.example/a.png"))
        XCTAssertNil(SportsTeam.logoURL("https://a.espncdn.com/a.html"))
        XCTAssertNotNil(SportsTeam.logoURL("https://a.espncdn.com/i/teamlogos/nfl/500/dal.png"))
    }
}

@MainActor final class PopupMenuTests: XCTestCase {
    func testPopupOutsideIslandKeepsItExpandedUntilMenuEnds() async throws {
        var config = CoveConfig(); config.calendar = false; config.sounds = false
        let model = IslandModel(config: config)
        model.setHovering(true); model.setExpanded(true)
        model.setMenuTracking(true); model.setHovering(false)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(model.expanded)
        model.setMenuTracking(false)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertFalse(model.expanded)
    }
    func testNestedMenusAndPointerReturnDoNotCollapse() async throws {
        var config = CoveConfig(); config.calendar = false; config.sounds = false
        let model = IslandModel(config: config)
        model.setExpanded(true); model.setMenuTracking(true); model.setMenuTracking(true)
        model.setHovering(false); model.setMenuTracking(false)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(model.expanded)
        model.setHovering(true); model.setMenuTracking(false)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertTrue(model.expanded)
    }
}
