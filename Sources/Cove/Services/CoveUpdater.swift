import AppKit
import Combine
#if canImport(Sparkle)
import Sparkle
#endif

/// Sparkle owns its preferences, archive verification and installation lifecycle.
@MainActor final class CoveUpdater: ObservableObject {
    @Published private(set) var canCheck = false
    @Published private(set) var automaticChecks = false
    @Published private(set) var automaticDownloads = false
    @Published private(set) var status = "Updates are available in the installed Cove app."
#if canImport(Sparkle)
    private var controller: SPUStandardUpdaterController?
    private var subscriptions = Set<AnyCancellable>()
#endif
    func start() {
#if canImport(Sparkle)
        guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") is String else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        self.controller = controller
        controller.updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main).assign(to: &$canCheck)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main).assign(to: &$automaticChecks)
        controller.updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: RunLoop.main).assign(to: &$automaticDownloads)
        status = "Checks daily. Updates are verified before installation."
        controller.startUpdater()
#endif
    }
    func check() {
#if canImport(Sparkle)
        guard canCheck else { return }
        controller?.checkForUpdates(nil)
#endif
    }
    func setAutomaticChecks(_ enabled: Bool) {
#if canImport(Sparkle)
        controller?.updater.automaticallyChecksForUpdates = enabled
#endif
    }
    func setAutomaticDownloads(_ enabled: Bool) {
#if canImport(Sparkle)
        controller?.updater.automaticallyDownloadsUpdates = enabled
#endif
    }
}
