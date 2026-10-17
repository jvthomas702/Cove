import XCTest
@testable import Cove

@MainActor final class ChargingAnimationTests: XCTestCase {
    private let unplugged = BatteryState(percent: 64, pluggedIn: false, charging: false)
    private let plugged = BatteryState(percent: 64, pluggedIn: true, charging: true)

    func testOnlyTheUnpluggedToPluggedChangeCounts() {
        XCTAssertTrue(BatteryState.justPluggedIn(from: unplugged, to: plugged))
        XCTAssertFalse(BatteryState.justPluggedIn(from: plugged, to: plugged))
        XCTAssertFalse(BatteryState.justPluggedIn(from: plugged, to: unplugged))
        XCTAssertFalse(BatteryState.justPluggedIn(from: unplugged, to: unplugged))
        // Launch (no earlier reading) and a lost reading never count.
        XCTAssertFalse(BatteryState.justPluggedIn(from: nil, to: plugged))
        XCTAssertFalse(BatteryState.justPluggedIn(from: unplugged, to: nil))
    }

    private func makeModel() -> IslandModel {
        var config = CoveConfig()
        config.sounds = false
        config.calendar = false
        config.buddyAlwaysVisible = false
        return IslandModel(config: config)
    }

    func testLaunchingOnPowerStaysQuiet() {
        let model = makeModel()
        model.setBattery(plugged)
        XCTAssertNil(model.chargingMoment)
        XCTAssertNil(model.compactItem)
        XCTAssertNil(model.banner)
    }

    func testPluggingInPlaysTheMomentInsteadOfTheBannerThenCollapses() async throws {
        let model = makeModel()
        model.setBattery(unplugged)
        model.setBattery(plugged)
        XCTAssertEqual(model.chargingMoment, plugged)
        XCTAssertEqual(model.compactItem, .charging(percent: 64))
        XCTAssertEqual(model.presentation, .compact)
        XCTAssertNil(model.banner, "the animation replaces the Charging banner")

        // Staying plugged in doesn't replay it.
        model.setBattery(BatteryState(percent: 65, pluggedIn: true, charging: true))
        XCTAssertEqual(model.chargingMoment, plugged)

        try await Task.sleep(nanoseconds: UInt64((IslandModel.chargingMomentSeconds + 0.5) * 1_000_000_000))
        XCTAssertNil(model.chargingMoment)
        XCTAssertNil(model.compactItem)
        XCTAssertEqual(model.presentation, .idle)
    }

    func testSettingOffKeepsTheChargingBanner() throws {
        XCTAssertTrue(try JSONDecoder().decode(CoveConfig.self, from: Data("{}".utf8)).chargingAnimation)
        let model = makeModel()
        model.config.chargingAnimation = false
        model.setBattery(unplugged)
        model.setBattery(plugged)
        XCTAssertNil(model.chargingMoment)
        XCTAssertEqual(model.banner?.title, "Charging")
    }
}
