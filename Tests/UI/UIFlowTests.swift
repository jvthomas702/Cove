import XCTest

final class UIFlowTests: XCTestCase {
    var app: XCUIApplication!
    var window: XCUIElement { app.windows["Cove UI Test"] }
    func text(_ value: String) -> XCUIElement {
        window.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", value, value)).firstMatch
    }
    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication(bundleIdentifier: "app.cove.ui-test")
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
    }
    override func tearDownWithError() throws {
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Native accessibility hierarchy"; hierarchy.lifetime = .keepAlways
        add(hierarchy)
        app.terminate()
    }

    func testSportsSelectionAndOfflineRecovery() {
        window.buttons["tab.sports"].click()
        let games = window.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sports.game."))
        XCTAssertTrue(games.firstMatch.waitForExistence(timeout: 8))
        games.firstMatch.click()
        XCTAssertTrue(window.scrollViews["sports.plays"].waitForExistence(timeout: 8))
        window.buttons["Offline"].click()
        XCTAssertTrue(text("Updates paused. Showing the last available data. Try refreshing.").waitForExistence(timeout: 8))
        XCTAssertTrue(window.scrollViews["sports.plays"].exists)
        window.buttons["Offline"].click()
        let cleared = NSPredicate(format: "exists == false")
        expectation(for: cleared, evaluatedWith: text("Updates paused. Showing the last available data. Try refreshing."))
        waitForExpectations(timeout: 8)
    }

    func testWidgetMenuAndQuietScreenshotPreserveChoice() {
        let chooser = window.popUpButtons["home.widget"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 8))
        chooser.click()
        app.menuItems["AI work"].click()
        XCTAssertTrue(text("Writing reply").waitForExistence(timeout: 5))
        window.buttons["Quiet screenshot"].click()
        XCTAssertTrue(text("Writing reply").exists)
        chooser.click()
        app.menuItems["Sports · play-by-play"].click()
        XCTAssertTrue(window.buttons["Play-by-play →"].waitForExistence(timeout: 5))
    }

    func testRealNotchPopupRemainsOpenOutsideIsland() {
        window.buttons["Show notch"].click()
        let notch = app.dialogs["Cove Test Notch"]
        let chooser = notch.popUpButtons["home.widget"]
        XCTAssertTrue(chooser.waitForExistence(timeout: 5))
        chooser.click()
        // Exercise the former 0.3-second collapse while a native popup extends outside the island.
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(chooser.exists)
        app.menuItems["AI work"].click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Writing reply", "Writing reply")).firstMatch.waitForExistence(timeout: 5))
    }

    func testCollegeFootballRankedFilter() {
        window.buttons["tab.sports"].click()
        window.radioButtons["College football"].click()
        let ranked = window.buttons["sports.game.401858488"]
        XCTAssertTrue(ranked.waitForExistence(timeout: 8))
        XCTAssertFalse(window.buttons["sports.game.401871067"].exists)
        window.checkBoxes["sports.top25"].click()
        XCTAssertTrue(window.buttons["sports.game.401871067"].waitForExistence(timeout: 5))
        ranked.click()
        XCTAssertTrue(text("Play-by-play").waitForExistence(timeout: 5))
        XCTAssertFalse(text("Updates paused.").exists)
    }

    func testAllTabsRemainUsable() {
        for tab in ["schedule", "sports", "shelf", "home"] {
            window.buttons["tab.\(tab)"].click()
            XCTAssertTrue(window.buttons["tab.\(tab)"].isHittable)
        }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Home UI"; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
