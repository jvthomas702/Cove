import XCTest
@testable import Cove

final class PermissionMemoryTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "cove.tests.permissions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    func testNothingIsLostUntilItWasGranted() {
        let store = defaults()
        XCTAssertEqual(Permission.lost(granted: [.accessibility: false, .calendars: false], defaults: store), [])
    }

    func testPermissionGrantedBeforeButNotNowIsLost() {
        let store = defaults()
        XCTAssertEqual(Permission.lost(granted: [.accessibility: true, .calendars: true], defaults: store), [])
        // An update with a new signature: macOS no longer trusts Cove for Accessibility.
        XCTAssertEqual(Permission.lost(granted: [.accessibility: false, .calendars: true], defaults: store), [.accessibility])
        // Allowing it again clears the warning.
        XCTAssertEqual(Permission.lost(granted: [.accessibility: true, .calendars: true], defaults: store), [])
    }

    func testDesktopFolderIsNotTracked() {
        let store = defaults()
        _ = Permission.lost(granted: [.desktop: true], defaults: store)
        XCTAssertEqual(Permission.lost(granted: [.desktop: false], defaults: store), [])
    }
}
