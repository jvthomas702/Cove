import AppKit
import Sparkle

@MainActor final class UpdateDelegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
    var controller: SPUStandardUpdaterController!
    func applicationDidFinishLaunching(_ notification: Notification) {
        setbuf(stdout, nil)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
        let marker = Bundle.main.object(forInfoDictionaryKey: "CoveTestMarker") as! String
        try? version.write(toFile: marker, atomically: true, encoding: .utf8)
        print("STARTED UPDATE FIXTURE \(version)")
        if version == "111" { NSApp.terminate(nil); return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.controller.updater.checkForUpdatesInBackground() }
    }
    @objc(updater:willInstallUpdateOnQuit:immediateInstallationBlock:)
    func install(_ updater: SPUUpdater, item: SUAppcastItem, immediate: @escaping () -> Void) -> Bool {
        print("INSTALLING UPDATE FIXTURE \(item.versionString)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: immediate)
        return true
    }
    @objc(updater:didAbortWithError:)
    func aborted(_ updater: SPUUpdater, error: Error) { print("UPDATE ERROR \(error.localizedDescription)") }
}

@main struct UpdateHost {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = UpdateDelegate(); app.delegate = delegate; app.run()
    }
}
