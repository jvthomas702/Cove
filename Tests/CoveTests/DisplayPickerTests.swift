import XCTest
@testable import Cove

@MainActor final class DisplayPickerTests: XCTestCase {
    // A MacBook (notch) with an external display to its right, and one stacked above it.
    private let laptop = ScreenDescriptor(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), hasNotch: true, isMain: false)
    private let external = ScreenDescriptor(frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440), hasNotch: false, isMain: true)
    private let above = ScreenDescriptor(frame: CGRect(x: 0, y: 982, width: 1920, height: 1080), hasNotch: false, isMain: false)

    func testNotchModePrefersTheNotchEvenWhenAnotherScreenIsMain() {
        XCTAssertEqual(DisplayPicker.pick([external, laptop], mode: .notch, mouse: CGPoint(x: 2000, y: 500)), 1)
    }

    func testNotchModeFallsBackToMainWhenDockedWithLidClosed() {
        var other = above; other.isMain = false
        XCTAssertEqual(DisplayPicker.pick([other, external], mode: .notch, mouse: nil), 1)
    }

    func testNotchModeFallsBackToFirstScreenWithoutMain() {
        var a = external; a.isMain = false
        XCTAssertEqual(DisplayPicker.pick([above, a], mode: .notch, mouse: nil), 0)
    }

    func testNoScreensPicksNothing() {
        XCTAssertNil(DisplayPicker.pick([], mode: .notch, mouse: nil))
        XCTAssertNil(DisplayPicker.pick([], mode: .active, mouse: .zero))
    }

    func testActiveModeFollowsThePointer() {
        let screens = [laptop, external, above]
        XCTAssertEqual(DisplayPicker.pick(screens, mode: .active, mouse: CGPoint(x: 700, y: 400)), 0)
        XCTAssertEqual(DisplayPicker.pick(screens, mode: .active, mouse: CGPoint(x: 3000, y: 900)), 1)
        XCTAssertEqual(DisplayPicker.pick(screens, mode: .active, mouse: CGPoint(x: 500, y: 1500)), 2)
    }

    func testActiveModeCountsTheTopEdgeAndSplitsSharedSideEdges() {
        // The pointer pushed against the top of the external display (y == maxY).
        XCTAssertEqual(DisplayPicker.pick([laptop, external], mode: .active, mouse: CGPoint(x: 2000, y: 1440)), 1)
        // Exactly on the border between side-by-side screens belongs to the right-hand one.
        XCTAssertEqual(DisplayPicker.pick([laptop, external], mode: .active, mouse: CGPoint(x: 1512, y: 100)), 1)
    }

    func testActiveModeFallsBackToMainThenNotchWhenPointerIsOffScreen() {
        let offscreen = CGPoint(x: -500, y: -500)
        XCTAssertEqual(DisplayPicker.pick([laptop, external], mode: .active, mouse: offscreen), 1)
        var notMain = external; notMain.isMain = false
        XCTAssertEqual(DisplayPicker.pick([above, notMain, laptop], mode: .active, mouse: offscreen), 2)
        XCTAssertEqual(DisplayPicker.pick([above, notMain, laptop], mode: .active, mouse: nil), 2)
    }

    func testSettingDefaultsToNotchAndRoundTrips() throws {
        let old = try JSONDecoder().decode(CoveConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(old.islandDisplay, .notch)
        let bogus = try JSONDecoder().decode(CoveConfig.self, from: Data(#"{"islandDisplay": "projector"}"#.utf8))
        XCTAssertEqual(bogus.islandDisplay, .notch)
        var config = old; config.islandDisplay = .active
        XCTAssertEqual(try JSONDecoder().decode(CoveConfig.self, from: JSONEncoder().encode(config)).islandDisplay, .active)
    }

    func testFloatingIslandSitsBelowTheTopEdgeOnlyWithoutANotch() {
        let model = IslandModel(config: CoveConfig())
        model.hasHardwareNotch = true
        XCTAssertEqual(model.islandTopInset, 0)
        model.hasHardwareNotch = false
        XCTAssertEqual(model.islandTopInset, IslandModel.floatingInset)
        XCTAssertGreaterThan(model.islandTopInset, 0)
    }
}
