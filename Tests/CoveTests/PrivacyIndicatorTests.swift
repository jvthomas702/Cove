import XCTest
@testable import Cove

@MainActor final class PrivacyIndicatorTests: XCTestCase {
    private let me: pid_t = 4242

    func testNothingRunningMeansNoDot() {
        let use = MediaUse.reduce(cameras: [CaptureReading(running: false)],
                                  microphones: [CaptureReading(running: false, pid: 10)], ownPID: me)
        XCTAssertEqual(use, MediaUse())
        XCTAssertNil(use.dot)
    }

    func testAnyRunningCameraOrMicrophoneCounts() {
        let cameras = [CaptureReading(running: false), CaptureReading(running: true)]
        XCTAssertEqual(MediaUse.reduce(cameras: cameras, microphones: [], ownPID: me), MediaUse(camera: true, microphone: false))
        let mics = [CaptureReading(running: false, pid: 1), CaptureReading(running: true, pid: 2)]
        XCTAssertEqual(MediaUse.reduce(cameras: [], microphones: mics, ownPID: me).dot, .microphone)
        // Input devices (macOS before 14.2) don't say which process is recording; they still count.
        XCTAssertEqual(MediaUse.reduce(cameras: [], microphones: [CaptureReading(running: true)], ownPID: me).dot, .microphone)
    }

    func testCoveItselfNeverCounts() {
        let use = MediaUse.reduce(cameras: [], microphones: [CaptureReading(running: true, pid: me)], ownPID: me)
        XCTAssertFalse(use.microphone)
        XCTAssertNil(use.dot)
    }

    func testCameraWinsOverMicrophoneLikeTheIPhone() {
        XCTAssertEqual(MediaUse(camera: true, microphone: true).dot, .camera)
        XCTAssertEqual(MediaUse(camera: false, microphone: true).dot, .microphone)
    }

    private func makeModel() -> IslandModel {
        var config = CoveConfig()
        config.sounds = false
        config.calendar = false
        config.buddyAlwaysVisible = false
        return IslandModel(config: config)
    }

    func testDotShowsOnItsOwnWhenNothingElseIs() {
        let model = makeModel()
        XCTAssertNil(model.compactItem)
        XCTAssertEqual(model.presentation, .idle)
        model.setMediaUse(MediaUse(camera: false, microphone: true))
        XCTAssertEqual(model.privacyDot, .microphone)
        XCTAssertEqual(model.compactItem, .privacy)
        XCTAssertEqual(model.presentation, .compact)
        model.setMediaUse(MediaUse())
        XCTAssertNil(model.compactItem)
        XCTAssertEqual(model.presentation, .idle)
    }

    func testDotRidesAlongWithOtherContentWithoutWideningTheIsland() {
        let model = makeModel()
        model.config.buddyAlwaysVisible = true
        let width = model.size(for: .compact).width
        model.setMediaUse(MediaUse(camera: true, microphone: false))
        XCTAssertEqual(model.compactItem, .napping)
        XCTAssertEqual(model.privacyDot, .camera)
        XCTAssertEqual(model.size(for: .compact).width, width)
    }

    func testSettingTurnsTheDotOff() throws {
        XCTAssertTrue(try JSONDecoder().decode(CoveConfig.self, from: Data("{}".utf8)).privacyIndicator)
        let model = makeModel()
        model.config.privacyIndicator = false
        model.setMediaUse(MediaUse(camera: true, microphone: true))
        XCTAssertNil(model.privacyDot)
        XCTAssertNil(model.compactItem)
    }
}
