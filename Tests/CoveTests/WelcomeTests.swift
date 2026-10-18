import XCTest
@testable import Cove

final class WelcomeTests: XCTestCase {
    private func allOff() -> CoveConfig {
        var config = CoveConfig()
        for feature in WelcomeFeature.all { feature.set(&config, false) }
        return config
    }

    func testNothingPickedNeedsNothing() {
        XCTAssertEqual(WelcomeFeature.neededPermissions(allOff()), [])
    }

    func testOnlyPickedFeaturesAskForPermissions() {
        var config = allOff()
        config.calendar = true
        config.sportsEnabled = true
        XCTAssertEqual(WelcomeFeature.neededPermissions(config), [.calendars, .reminders])

        config.hud = "replace"
        config.screenshotsToShelf = true
        XCTAssertEqual(WelcomeFeature.neededPermissions(config), [.calendars, .reminders, .accessibility, .desktop])
    }

    func testTogglesRoundTrip() {
        var config = CoveConfig()
        for feature in WelcomeFeature.all {
            feature.set(&config, false)
            XCTAssertFalse(feature.isOn(config), feature.id)
            feature.set(&config, true)
            XCTAssertTrue(feature.isOn(config), feature.id)
        }
        // Turning the meter off keeps Cove's HUD beside the system one rather than removing it.
        WelcomeFeature.all.first { $0.id == "hud" }!.set(&config, false)
        XCTAssertEqual(config.hud, "passive")
    }

    func testDefaultsAskForEverythingTheyUse() {
        let needed = WelcomeFeature.neededPermissions(CoveConfig())
        XCTAssertTrue(needed.contains(.calendars))
        XCTAssertTrue(needed.contains(.accessibility))
    }
}
