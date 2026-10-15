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
        print(app.debugDescription)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Native accessibility hierarchy"; hierarchy.lifetime = .keepAlways
        add(hierarchy)
        app.terminate()
    }

    func testSportsSelectionAndOfflineRecovery() {
        window.buttons["tab.sports"].click()
        window.buttons["sports.games"].click()
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
        window.buttons["tab.ai"].click()
        XCTAssertTrue(text("Writing reply").waitForExistence(timeout: 5))
        window.buttons["Quiet screenshot"].click()
        XCTAssertTrue(window.scrollViews["ai.detail"].exists)
        XCTAssertTrue(text("Writing reply").exists)
        window.buttons["tab.home"].click()
        XCTAssertTrue(window.buttons["Play-by-play →"].waitForExistence(timeout: 5))
    }

    func testRealNotchPopupRemainsOpenOutsideIsland() {
        window.buttons["Show notch"].click()
        let notch = app.dialogs["Cove Test Notch"]
        let devices = notch.descendants(matching: .any).matching(identifier: "device.settings").firstMatch
        XCTAssertTrue(devices.waitForExistence(timeout: 5))
        devices.click()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(devices.exists)
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        notch.buttons["tab.ai"].click()
        XCTAssertTrue(notch.scrollViews["ai.detail"].waitForExistence(timeout: 5))
        XCTAssertTrue(notch.buttons["notch.pin"].exists)
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

    func testBasketballGamecastQuarterScoringAndStats() {
        window.buttons["tab.sports"].click()
        window.buttons["sports.games"].click()
        window.buttons["sports.game.401810946"].click()
        let period = window.popUpButtons["sports.period"]
        XCTAssertTrue(period.waitForExistence(timeout: 5))
        period.click(); app.menuItems["Q1"].click()
        window.checkBoxes["sports.scoring"].click()
        let row = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "sports.play.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue((row.label + String(describing: row.value ?? "")).contains("Q1"))
        XCTAssertTrue((row.label + String(describing: row.value ?? "")).contains("+"))
        window.radioButtons["Stats"].click()
        XCTAssertTrue(window.scrollViews["sports.stats"].waitForExistence(timeout: 5))
        XCTAssertTrue(text("Team stats").exists)
        XCTAssertTrue(text("MIA").exists)
    }

    func testFootballGamecastDrivesAndDownDistance() {
        window.buttons["tab.sports"].click()
        window.radioButtons["NFL"].click()
        let game = window.buttons["sports.game.401772918"]
        XCTAssertTrue(game.waitForExistence(timeout: 5)); game.click()
        window.checkBoxes["sports.scoring"].click()
        let row = window.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "sports.play.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        let content = row.label + String(describing: row.value ?? "")
        XCTAssertTrue(content.contains("Field Goal"))
        XCTAssertTrue(content.contains("&"))
        window.radioButtons["Drives"].click()
        XCTAssertTrue(window.scrollViews["sports.drives"].waitForExistence(timeout: 5))
        XCTAssertTrue(text("Drive chart").exists)
    }

    func testBundledTeamLogosRemainVisibleOffline() {
        window.buttons["tab.sports"].click()
        let logo = window.images.matching(identifier: "sports.logo.nba.20").firstMatch
        XCTAssertTrue(logo.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(logo.frame.width, 0)
        window.buttons["Offline"].click()
        XCTAssertTrue(text("Updates paused.").waitForExistence(timeout: 8))
        XCTAssertGreaterThan(logo.frame.width, 0)
    }

    func testScreenshotStaysOnShelfAcrossTabs() {
        window.buttons["Quiet screenshot"].click()
        window.buttons["tab.shelf"].click()
        let item = window.descendants(matching: .any).matching(identifier: "shelf.item.Cove UI Screenshot.png").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        window.buttons["tab.home"].click()
        XCTAssertTrue(window.buttons["home.openGamecast"].waitForExistence(timeout: 5))
        window.buttons["tab.shelf"].click()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        window.buttons["Delete source"].click()
        app.terminate()
        app.launchArguments = ["--preserve-shelf"]
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.buttons["tab.shelf"].click()
        XCTAssertTrue(item.waitForExistence(timeout: 5))
    }

    func testPinnedNotchAndAnchoredTabPositions() {
        window.buttons["Show notch"].click()
        let notch = app.dialogs["Cove Test Notch"]
        let pin = notch.buttons["notch.pin"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5)); pin.click()
        window.buttons["Offline"].click()
        Thread.sleep(forTimeInterval: 0.6)
        XCTAssertTrue(pin.exists)
        let home = notch.buttons["tab.home"]
        let original = home.frame
        notch.buttons["tab.sports"].click()
        XCTAssertTrue(notch.scrollViews["sports.plays"].waitForExistence(timeout: 5))
        XCTAssertEqual(home.frame.minX, original.minX, accuracy: 2)
        notch.buttons["tab.shelf"].click()
        XCTAssertTrue(notch.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Drop files")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(home.frame.minX, original.minX, accuracy: 2)
        notch.buttons["notch.close"].click()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: pin)
        waitForExpectations(timeout: 5)
    }

    func testMultipleScoresAndAIOverviewSelection() {
        window.descendants(matching: .any).matching(identifier: "ui.fixtures").firstMatch.click(); app.menuItems["Follow slate"].click()
        window.buttons["tab.sports"].click()
        XCTAssertTrue(window.scrollViews["sports.followedScores"].waitForExistence(timeout: 8))
        window.buttons["tab.home"].click()
        XCTAssertTrue(window.buttons["home.openGamecast"].waitForExistence(timeout: 5))
        window.descendants(matching: .any).matching(identifier: "ui.fixtures").firstMatch.click(); app.menuItems["Add AI task"].click()
        window.buttons["tab.ai"].click()
        XCTAssertTrue(window.scrollViews["ai.overview"].waitForExistence(timeout: 5))
        let task = window.buttons["ai.task.web:claude:ui:tab:2"]
        XCTAssertTrue(task.waitForExistence(timeout: 5)); task.click()
        XCTAssertTrue(window.buttons["Open Claude"].waitForExistence(timeout: 5))
        XCTAssertTrue(text("Reasoning").exists)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "AI task overview"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testShelfUndoRenameAndAnnotation() {
        window.buttons["Quiet screenshot"].click(); window.buttons["tab.shelf"].click()
        let item = window.descendants(matching: .any).matching(identifier: "shelf.item.Cove UI Screenshot.png").firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        window.buttons["shelf.clear"].click()
        let undo = window.buttons["shelf.undo"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5)); undo.click()
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.doubleClick()
        let editor = app.windows["Cove Image Preview"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let name = editor.textFields["shelf.rename"]
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("Renamed capture")
        XCTAssertEqual(name.value as? String, "Renamed capture")
        editor.buttons["shelf.renameSave"].click()
        XCTAssertTrue(editor.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Renamed saved copy")).firstMatch.waitForExistence(timeout: 5))
        editor.radioButtons["Pen"].click()
        let canvas = editor.descendants(matching: .any).matching(identifier: "shelf.annotationCanvas").firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let before = XCTAttachment(screenshot: editor.screenshot())
        before.name = "Editor before drawing"; before.lifetime = .keepAlways; add(before)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).click(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        let save = editor.buttons["shelf.saveAnnotation"]
        XCTAssertTrue(save.isEnabled); save.click()
        XCTAssertTrue(editor.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Annotated copy saved")).firstMatch.waitForExistence(timeout: 5))
        editor.radioButtons["Text"].click()
        editor.textFields["shelf.annotationText"].click()
        editor.textFields["shelf.annotationText"].typeText("Review note")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.15)).click()
        XCTAssertTrue(editor.buttons["Undo mark"].isEnabled)
        editor.buttons["Undo mark"].click()
        let attachment = XCTAttachment(screenshot: editor.screenshot())
        attachment.name = "Screenshot editor"; attachment.lifetime = .keepAlways; add(attachment)
        editor.buttons["_XCUI:CloseWindow"].click()
    }

    func testAllTabsRemainUsable() {
        for tab in ["ai", "schedule", "sports", "shelf", "home"] {
            window.buttons["tab.\(tab)"].click()
            XCTAssertTrue(window.buttons["tab.\(tab)"].isHittable)
        }
        Thread.sleep(forTimeInterval: 0.7)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Home UI"; attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testBlackDashboardAndGamecastInBothSystemAppearances() {
        for theme in ["dark", "light-system"] {
            app.terminate()
            app.launchArguments = theme == "light-system" ? ["--light-system"] : []
            app.launch()
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            var previousEdge: CGFloat = 0
            for tile in ["music", "sports", "activity", "connections"] {
                let element = window.descendants(matching: .any).matching(identifier: "home.\(tile)Tile").firstMatch
                XCTAssertTrue(element.waitForExistence(timeout: 8))
                XCTAssertGreaterThan(element.frame.width, 100)
                XCTAssertGreaterThanOrEqual(element.frame.minX, previousEdge)
                previousEdge = element.frame.maxX
            }
            let appearance = window.descendants(matching: .any).matching(identifier: "island.settings").firstMatch
            XCTAssertTrue(appearance.exists)
            window.buttons["Show notch"].click()
            let notch = app.dialogs["Cove Test Notch"]
            let pin = notch.buttons["notch.pin"]
            XCTAssertTrue(pin.waitForExistence(timeout: 5)); pin.click()
            let dashboard = XCTAttachment(screenshot: notch.screenshot())
            dashboard.name = "\(theme.capitalized) Matte Dashboard"; dashboard.lifetime = .keepAlways; add(dashboard)
            notch.buttons["notch.close"].click()
            window.buttons["Hide notch"].click()
            window.buttons["home.openGamecast"].click()
            XCTAssertTrue(window.scrollViews["sports.plays"].waitForExistence(timeout: 8))
            window.radioButtons["Stats"].click()
            XCTAssertTrue(window.scrollViews["sports.stats"].waitForExistence(timeout: 5))
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "\(theme.capitalized) Matte Gamecast"; attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testBlackAICompanionInBothSystemAppearances() {
        for theme in ["dark", "light-system"] {
            app.terminate()
            app.launchArguments = theme == "light-system" ? ["--light-system"] : []
            app.launch()
            XCTAssertTrue(window.waitForExistence(timeout: 10))
            window.buttons["home.activity.web:chatgpt:ui:tab:1"].click()
            let companion = window.descendants(matching: .any).matching(identifier: "ai.companion").firstMatch
            XCTAssertTrue(companion.waitForExistence(timeout: 8))
            XCTAssertTrue(window.scrollViews["ai.detail"].exists)
            window.descendants(matching: .any).matching(identifier: "ui.fixtures").firstMatch.click()
            app.menuItems["Add AI task"].click()
            let second = window.buttons["ai.task.web:claude:ui:tab:2"]
            XCTAssertTrue(second.waitForExistence(timeout: 5)); second.click()
            XCTAssertTrue(window.buttons["Open Claude"].waitForExistence(timeout: 5))
            XCTAssertTrue(text("A second simulated response").exists)
            XCTAssertTrue(window.scrollViews["ai.steps"].exists)
            let screenshot = XCTAttachment(screenshot: window.screenshot())
            screenshot.name = "\(theme.capitalized) Matte AI workspace"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
    }
    func testAIConnectionsAreAvailableFromEveryTab() {
        for tab in ["home", "schedule", "sports", "shelf", "ai"] {
            window.buttons["tab.\(tab)"].click()
            XCTAssertTrue(window.buttons["ai.connect"].isHittable)
        }
        window.buttons["ai.connect"].click()
        let settings = app.windows["Cove Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        for title in ["AI connections", "Claude Code", "Codex", "ChatGPT desktop"] {
            let label = settings.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", title, title)).firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 5))
        }
        XCTAssertTrue(settings.staticTexts["Tracking is off"].exists)
        XCTAssertFalse(settings.buttons["Allow Accessibility…"].exists)
        let screenshot = XCTAttachment(screenshot: settings.screenshot())
        screenshot.name = "AI connections"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testAIFiltersKeepDetailsInSyncAndRecoverFromEmptyResults() {
        window.buttons["home.viewAI"].click()
        window.buttons["ai.filter.done"].click()
        XCTAssertTrue(text("No finished tasks yet").waitForExistence(timeout: 5))
        XCTAssertFalse(window.buttons["Open ChatGPT"].exists)
        window.buttons["ai.emptyAction"].click()
        XCTAssertTrue(window.buttons["Open ChatGPT"].waitForExistence(timeout: 5))
        window.descendants(matching: .any).matching(identifier: "ui.fixtures").firstMatch.click()
        app.menuItems["Finish AI task"].click()
        window.buttons["ai.filter.live"].click()
        XCTAssertTrue(text("Nothing working right now").waitForExistence(timeout: 5))
        XCTAssertFalse(window.buttons["Open ChatGPT"].exists)
        window.buttons["ai.filter.done"].click()
        XCTAssertTrue(text("Finished simulated reply").waitForExistence(timeout: 5))
        XCTAssertTrue(window.buttons["Open ChatGPT"].exists)
    }

    func testEmptyAIWorkspaceOpensConnectionsInLightSystemAppearance() {
        app.terminate()
        app.launchArguments = ["--no-ai", "--light-system"]
        app.launch()
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        window.buttons["tab.ai"].click()
        XCTAssertTrue(text("Ready for your next task").waitForExistence(timeout: 5))
        XCTAssertTrue(text("Tracking is off").exists)
        window.buttons["ai.emptyAction"].click()
        let settings = app.windows["Cove Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: settings.screenshot())
        screenshot.name = "Black settings in light macOS appearance"; screenshot.lifetime = .keepAlways; add(screenshot)
    }

    func testAgentPromptSurvivesTabSwitchAndStartsOnlyWhenSubmitted() {
        window.buttons["tab.ai"].click()
        let prompt = window.descendants(matching: .any).matching(identifier: "agent.prompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5)); prompt.click()
        prompt.typeText("Explain this project without changes")
        window.buttons["tab.home"].click(); window.buttons["tab.ai"].click()
        XCTAssertEqual(window.descendants(matching: .any).matching(identifier: "agent.prompt").firstMatch.value as? String, "Explain this project without changes")
        window.buttons["agent.start"].click()
        XCTAssertTrue(text("Opened Codex in Terminal").waitForExistence(timeout: 5))
        XCTAssertEqual(window.descendants(matching: .any).matching(identifier: "agent.prompt").firstMatch.value as? String, "")
    }

    func testRealNotchAcceptsAgentTypingAndStaysOpen() {
        window.buttons["Show notch"].click()
        let notch = app.dialogs["Cove Test Notch"]
        notch.buttons["tab.ai"].click()
        let prompt = notch.descendants(matching: .any).matching(identifier: "agent.prompt").firstMatch
        XCTAssertTrue(prompt.waitForExistence(timeout: 5)); prompt.click(); prompt.typeText("Review this code")
        XCTAssertEqual(prompt.value as? String, "Review this code")
        window.buttons["Offline"].click()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(prompt.exists)
        XCTAssertEqual(prompt.value as? String, "Review this code")
    }

}
