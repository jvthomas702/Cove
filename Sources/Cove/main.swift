import AppKit

// Cove — a Dynamic Island for the MacBook notch.
// Runs as an accessory app (no Dock icon); the menu bar capsule icon has Quit and settings.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
