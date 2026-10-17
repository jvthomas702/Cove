import XCTest
@testable import Cove

final class GamecastTests: XCTestCase {
    func data(_ name: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")))
    }
    func testKeepsWholeBasketballGameAndResolvesPlayers() throws {
        let snapshot = try SportsParser.gameSummary(data("nba-gamecast"), league: .nba)
        XCTAssertEqual(snapshot.plays.count, 475)
        XCTAssertEqual(snapshot.plays.first?.text, "End of Game")
        XCTAssertEqual(snapshot.plays.last?.clock, "12:00")
        let firstBasket = try XCTUnwrap(snapshot.plays.first { $0.id == "4018109467" })
        XCTAssertEqual(firstBasket.badge, "+2")
        XCTAssertEqual(firstBasket.athleteNames, ["Pelle Larsson", "Bam Adebayo"])
        XCTAssertEqual(firstBasket.teamID, snapshot.game?.home.id)
        XCTAssertEqual(snapshot.game?.home.periodScores, ["38", "20", "33", "28"])
    }
    func testQuarterAndScoringFiltersIncludeEarlyGame() throws {
        let plays = try SportsParser.gameSummary(data("nba-gamecast"), league: .nba).plays
        let q1 = SportsPlayFilter.apply(plays, period: 1, scoringOnly: true)
        XCTAssertGreaterThan(q1.count, 20)
        XCTAssertTrue(q1.allSatisfy { $0.period == 1 && $0.scoring })
        XCTAssertTrue(q1.contains { $0.id == "4018109467" })
        XCTAssertEqual(SportsPlayFilter.apply(plays, period: nil, scoringOnly: false), plays)
        XCTAssertTrue(SportsPlayFilter.apply(plays, period: 9, scoringOnly: true).isEmpty)
    }
    func testFootballDownDistanceDrivesAndScoringTeam() throws {
        let snapshot = try SportsParser.gameSummary(data("nfl-gamecast"), league: .nfl)
        XCTAssertEqual(snapshot.plays.count, 197)
        let touchdown = try XCTUnwrap(snapshot.plays.first { $0.id == "401772918243" })
        XCTAssertEqual(touchdown.downDistance, "2nd & 11")
        XCTAssertEqual(touchdown.fieldPosition, "BAL 15")
        XCTAssertEqual(touchdown.yards, 15)
        XCTAssertEqual(touchdown.teamID, snapshot.game?.home.id)
        XCTAssertEqual(touchdown.badge, "Touchdown")
        XCTAssertNotNil(touchdown.driveID)
        XCTAssertTrue(snapshot.drives.contains { $0.summary == "7 plays, 50 yards, 3:41" && $0.result == "Touchdown" })
        XCTAssertTrue(snapshot.drives.allSatisfy { !$0.current }) // A final game never claims an active drive.
        XCTAssertNil(snapshot.situation)
    }
    func testStatsAreMappedByTeamRatherThanProviderOrder() throws {
        let snapshot = try SportsParser.gameSummary(data("nba-gamecast"), league: .nba)
        let rebounds = try XCTUnwrap(snapshot.stats.first { $0.id == "totalRebounds" })
        XCTAssertEqual(rebounds.values["20"], "42")
        XCTAssertEqual(snapshot.leaders.first { $0.teamID == "14" && $0.category == "Points" }?.name, "Tyler Herro")
        XCTAssertEqual(snapshot.leaders.first { $0.teamID == "14" && $0.category == "Points" }?.value, "30")
        XCTAssertEqual(Set(snapshot.stats.map(\.id)).count, snapshot.stats.count)
    }
    func testCollegeFootballHasFullDriveFeed() throws {
        let snapshot = try SportsParser.gameSummary(data("cfb-gamecast"), league: .collegeFootball)
        XCTAssertGreaterThan(snapshot.plays.count, 100)
        XCTAssertGreaterThan(snapshot.drives.count, 10)
        XCTAssertTrue(snapshot.plays.contains { !$0.context.isEmpty && $0.teamID != nil })
        XCTAssertTrue(snapshot.plays.contains { $0.scoring })
    }
    func testCorrectionsReplaceRepeatedPlayAndDoNotInventContext() throws {
        var json = try JSONSerialization.jsonObject(with: data("nba-gamecast")) as! [String: Any]
        var plays = json["plays"] as! [[String: Any]]
        var corrected = plays[0]; corrected["text"] = "Corrected jump ball"
        plays.append(corrected); json["plays"] = plays
        let parsed = try SportsParser.gameSummary(JSONSerialization.data(withJSONObject: json), league: .nba)
        XCTAssertEqual(parsed.plays.count, 475)
        XCTAssertEqual(parsed.plays.last?.text, "Corrected jump ball")
        XCTAssertTrue(parsed.plays.last?.context.isEmpty == true)
        XCTAssertNil(parsed.plays.last?.yards)
        json["plays"] = nil; json["boxscore"] = nil; json["leaders"] = nil
        let unavailable = try SportsParser.gameSummary(JSONSerialization.data(withJSONObject: json), league: .nba)
        XCTAssertTrue(unavailable.plays.isEmpty && unavailable.stats.isEmpty && unavailable.leaders.isEmpty)
    }
    func testGamecastLinksRequireNumericEventID() {
        var game = SportsGame(id: "123", league: .nba, start: nil,
            away: SportsTeam(name: "Away", abbreviation: "A", score: "0", rank: nil),
            home: SportsTeam(name: "Home", abbreviation: "H", score: "0", rank: nil), state: "pre", status: "Scheduled")
        XCTAssertEqual(game.gamecastURL?.host, "www.espn.com")
        game.id = "bad?id=other"; XCTAssertNil(game.gamecastURL)
    }
}
