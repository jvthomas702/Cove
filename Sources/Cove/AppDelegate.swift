import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: IslandModel!
    private var windowController: NotchWindowController!
    private var agents: AgentBridge!
    private var server: EventServer?
    private var nowPlaying: NowPlayingMonitor?
    private var mirror: NotificationMirror?
    private let battery = BatteryMonitor()
    private var calendar: CalendarMonitor?
    private var screenshots: ScreenshotWatcher?
    private let volume = VolumeController()
    private let mediaKeys = MediaKeyTap()
    private var volumeStarted = false
    private var trustTimer: Timer?
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var hideItem: NSMenuItem!
    private var hiddenUntil: Date?
    private var unhideTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var settingsController: SettingsController!
    private var settingsWindow: SettingsWindowController?

    /// Extra routes used by CI to drive the UI for screenshots. Only on with the `--debug-api` launch argument.
    private let debugAPI = CommandLine.arguments.contains("--debug-api")

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !anotherCopyIsRunning() else {
            NSApp.terminate(nil)
            return
        }
        coveLog.info("Cove \(self.version, privacy: .public) starting")

        let config = CoveConfig.load()
        model = IslandModel(config: config)
        windowController = NotchWindowController(model: model)
        agents = AgentBridge(model: model)

        settingsController = SettingsController(model: model)
        settingsController.onConfigChange = { [weak self] config in self?.updateConfig(config) }
        settingsController.onRunDemo = { [weak self] in self?.runDemo() }
        settingsController.onCopyDiagnostics = { [weak self] in self?.copyDiagnostics() }
        settingsController.onPermissionChanged = { [weak self] permission in
            guard let self, permission == .calendars || permission == .reminders else { return }
            if let calendar = self.calendar { calendar.refresh() } else if self.model.config.calendar { self.startCalendar(self.model.config) }
        }
        settingsController.onRecheckScreenshots = { [weak self] in
            guard let self else { return }
            if let watcher = self.screenshots { watcher.recheckAccess() } else { self.startScreenshots() }
        }

        startServer(port: config.port)
        startMedia(apps: config.mediaApps)
        if config.mirrorNotifications { startMirror() }
        battery.onChange = { [weak self] state in self?.model.setBattery(state) }
        battery.start()
        if config.calendar { startCalendar(config) }
        if config.screenshotsToShelf { startScreenshots() }
        startHUD(mode: config.hud)
        BrowserExtension.syncFromBundle()

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundleID = app?.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.model.appActivated(bundleID) }
        })
        // Coming back from sleep: refresh things that may have changed while the lid was closed.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.calendar?.refresh()
                self?.screenshots?.recheckAccess()
                self?.windowController.relocate()
            }
        })

        buildStatusItem()
        welcomeIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        mirror?.stop()
        nowPlaying?.stop()
        battery.stop()
        calendar?.stop()
        screenshots?.stop()
        volume.stop()
        mediaKeys.stop()
    }

    /// Opening Cove.app again (Finder, Spotlight) opens Settings rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return false
    }

    private func anotherCopyIsRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != mine }
        if let other = others.first {
            coveLog.info("Another Cove (pid \(other.processIdentifier)) is already running; quitting this one")
            return true
        }
        return false
    }

    /// First launch: open Settings on the Permissions page. After an update: a small "updated" banner.
    private func welcomeIfNeeded() {
        let defaults = UserDefaults.standard
        let last = defaults.string(forKey: "lastLaunchedVersion")
        defaults.set(version, forKey: "lastLaunchedVersion")
        if last == nil {
            model.show(Banner(
                title: "Hi, I'm Pip",
                body: "Hover the notch to open Cove. Let's set up permissions.",
                style: .success,
                icon: .buddy(.happy, nil),
                source: "Welcome to Cove"
            ))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.openSettings(pane: .permissions) }
            }
        } else if last != version {
            model.show(Banner(
                title: "Cove updated to \(version)",
                body: "Hover the notch to see what's new.",
                style: .success,
                icon: .buddy(.happy, nil),
                source: "Updated"
            ))
        }
    }

    // MARK: - Settings

    private func openSettings(pane: SettingsPane = .general) {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(controller: settingsController) }
        settingsWindow?.show(pane: pane)
    }

    /// Saves a changed config and applies it to the running services.
    private func updateConfig(_ new: CoveConfig) {
        let old = model.config
        CoveConfig.save(new)
        model.config = new

        if new.calendar != old.calendar {
            if new.calendar { startCalendar(new) } else { calendar?.stop(); calendar = nil; model.setSchedule(Schedule()) }
        } else {
            calendar?.update(config: new)
        }
        if new.mirrorNotifications != old.mirrorNotifications {
            if new.mirrorNotifications { startMirror() } else { mirror?.stop(); mirror = nil }
        }
        if new.screenshotsToShelf != old.screenshotsToShelf {
            if new.screenshotsToShelf { startScreenshots() } else { screenshots?.stop(); screenshots = nil }
        }
        if new.hud != old.hud {
            stopHUD()
            startHUD(mode: new.hud)
        }
        if new.mediaApps != old.mediaApps {
            nowPlaying?.stop()
            startMedia(apps: new.mediaApps)
        }
        if new.port != old.port {
            server?.stop()
            startServer(port: new.port)
        }
    }

    // MARK: - Services

    private func startServer(port: UInt16) {
        let server = EventServer(port: port) { [weak self] exchange in
            guard let self else {
                exchange.respond(503, #"{"error":"shutting down"}"#)
                return
            }
            self.route(exchange)
        }
        server.onState = { [weak self] text in
            self?.model.serverStatus = text
            self?.statusLine?.title = "Cove \(self?.version ?? "") — \(text)"
        }
        do {
            try server.start()
            self.server = server
        } catch {
            coveLog.error("Server failed to start on \(port): \(error.localizedDescription, privacy: .public)")
            model.serverStatus = "port \(port) unavailable"
            model.show(Banner(
                title: "Couldn't start on port \(port)",
                body: "Another app is using it. Change the port in Cove's settings file.",
                style: .failure,
                icon: .symbol("exclamationmark.triangle.fill", Palette.red),
                sticky: true
            ))
        }
    }

    private func route(_ exchange: HTTPExchange) {
        let ok = #"{"ok":true}"#
        if exchange.method == "OPTIONS" {
            exchange.respond(204, "") // CORS preflight from the browser extension
            return
        }
        if debugAPI, exchange.path.hasPrefix("/debug/") {
            debugRoute(exchange.path)
            exchange.respond(200, ok)
            return
        }
        switch (exchange.method, exchange.path) {
        case ("GET", "/health"):
            exchange.respond(200, #"{"ok":true,"app":"cove","version":"\#(version)"}"#)
        case ("POST", "/event"):
            guard let event = try? JSONDecoder().decode(CoveEvent.self, from: exchange.body) else {
                exchange.respond(400, #"{"error":"expected JSON with at least a \"title\""}"#)
                return
            }
            model.ingest(event)
            exchange.respond(200, ok)
        case ("POST", "/hook/claude"):
            agents.handleClaude(exchange.body)
            exchange.respond(200, ok)
        case ("POST", "/hook/claude/permission"):
            agents.handlePermission(exchange) // answers later, when you click
        case ("POST", "/hook/codex"):
            agents.handleCodex(exchange.body)
            exchange.respond(200, ok)
        default:
            exchange.respond(404, #"{"error":"not found"}"#)
        }
    }

    private func startCalendar(_ config: CoveConfig) {
        calendar?.stop()
        let monitor = CalendarMonitor(config: config)
        monitor.onUpdate = { [weak self] schedule in self?.model.setSchedule(schedule) }
        monitor.onStatus = { [weak self] status in
            if self?.model.calendarStatus != status { self?.model.calendarStatus = status }
        }
        monitor.onAccessDenied = { [weak self] in
            self?.model.show(Banner(
                title: "Calendar access is off",
                body: "Click to allow Cove in Settings → Privacy → Calendars and Reminders.",
                style: .info,
                icon: .symbol("calendar.badge.exclamationmark", Palette.amber),
                openURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")
            ))
        }
        monitor.start()
        calendar = monitor
    }

    private func startScreenshots() {
        screenshots?.stop()
        let watcher = ScreenshotWatcher()
        watcher.onNew = { [weak self] urls in self?.model.addScreenshots(urls) }
        watcher.onAccess = { [weak self] state, folder in self?.model.setScreenshotAccess(state, folder: folder) }
        watcher.start()
        screenshots = watcher
    }

    private func startMedia(apps: [String]) {
        let monitor = NowPlayingMonitor(apps: apps)
        monitor.onUpdate = { [weak self] np in self?.model.setNowPlaying(np) }
        monitor.onArtwork = { [weak self] key, data in self?.model.setArtwork(data, forTrack: key) }
        model.mediaControl = { [weak monitor] command, bundleID in monitor?.send(command, to: bundleID) }
        monitor.start()
        nowPlaying = monitor
    }

    private func startMirror() {
        mirror?.stop()
        let mirror = NotificationMirror()
        mirror.onItems = { [weak self] items in
            for item in items { self?.model.mirrored(item) }
        }
        mirror.onAccessDenied = { [weak self] in self?.model.notificationAccessDenied() }
        mirror.start()
        self.mirror = mirror
    }

    // MARK: - Volume & brightness HUD

    private func startHUD(mode: String) {
        let mode = mode.lowercased()
        guard mode != "off" else { return }
        volume.onChange = { [weak self] level, muted in
            self?.model.showHUD(.volume, level: Double(level), muted: muted)
        }
        if !volumeStarted {
            volume.start()
            volumeStarted = true
        }
        guard mode == "replace" else { return }

        mediaKeys.handler = { [weak self] key, isDown, _, fine in
            self?.handleMediaKey(key, isDown: isDown, fine: fine) ?? false
        }
        if MediaKeyTap.isTrusted {
            mediaKeys.start()
        } else {
            // Start the tap as soon as Accessibility is granted; until then the passive HUD still works.
            trustTimer?.invalidate()
            trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard MediaKeyTap.isTrusted else { return }
                    timer.invalidate()
                    self?.mediaKeys.start()
                }
            }
        }
    }

    private func stopHUD() {
        trustTimer?.invalidate()
        trustTimer = nil
        mediaKeys.stop()
        volume.onChange = nil
    }

    /// Returns true when Cove handled the key (so macOS doesn't show its own pop-up).
    private func handleMediaKey(_ key: MediaKeyTap.Key, isDown: Bool, fine: Bool) -> Bool {
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16
        switch key {
        case .volumeUp, .volumeDown, .mute:
            guard volume.canSetVolume else { return false }
            guard isDown else { return true }
            if key == .mute {
                volume.setMuted(!volume.isMuted)
            } else {
                let current = volume.volume ?? 0
                let next = key == .volumeUp ? current + step : current - step
                volume.setVolume((next / step).rounded() * step)
                if key == .volumeDown && next <= 0.001 { volume.setMuted(true) }
            }
            model.showHUD(.volume, level: Double(volume.volume ?? 0), muted: volume.isMuted)
            return true
        case .brightnessUp, .brightnessDown:
            guard DisplayBrightness.isAvailable else { return false }
            guard isDown else { return true }
            let current = DisplayBrightness.level ?? 0.5
            let next = key == .brightnessUp ? current + step : current - step
            DisplayBrightness.set((next / step).rounded() * step)
            model.showHUD(.brightness, level: Double(DisplayBrightness.level ?? next))
            return true
        }
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarGlyph()
        statusItem.button?.toolTip = "Cove"

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Cove \(version) — \(model.serverStatus)", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        addItem(to: menu, "Settings…", #selector(openSettingsFromMenu), key: ",")
        addItem(to: menu, "Run demo", #selector(runDemoFromMenu))
        addItem(to: menu, "Send test notification", #selector(sendTest))
        menu.addItem(.separator())
        hideItem = addItem(to: menu, "Hide for an hour", #selector(toggleHidden))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Cove", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        statusItem.menu = menu
    }

    /// A tiny screen with the island hanging from its top edge (template, so it follows the menu bar's color).
    private static func menuBarGlyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let screen = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3.5, width: 15, height: 11), xRadius: 3, yRadius: 3)
            screen.lineWidth = 1.3
            screen.stroke()
            let island = NSBezierPath(roundedRect: NSRect(x: 5.5, y: 10.5, width: 7, height: 4), xRadius: 2, yRadius: 2)
            island.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Cove"
        return image
    }

    @discardableResult
    private func addItem(to menu: NSMenu, _ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func openSettingsFromMenu() { openSettings() }
    @objc private func runDemoFromMenu() { runDemo() }

    @objc private func sendTest() {
        model.ingest(CoveEvent(title: "Hello from Cove 👋", body: "This is what a notification looks like.", kind: "info"))
    }

    @objc private func toggleHidden() {
        unhideTimer?.invalidate()
        if hiddenUntil == nil {
            hiddenUntil = Date().addingTimeInterval(3600)
            windowController.panel.orderOut(nil)
            hideItem.title = "Show Cove"
            unhideTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.toggleHidden() }
            }
        } else {
            hiddenUntil = nil
            windowController.panel.orderFrontRegardless()
            hideItem.title = "Hide for an hour"
        }
    }

    // MARK: - Diagnostics

    private func copyDiagnostics() {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var lines = [
            "Cove \(version) on macOS \(os)",
            "Server: \(model.serverStatus)",
            "Notch: \(Int(model.notchSize.width))×\(Int(model.notchSize.height)) (hardware: \(model.hasHardwareNotch))",
            "Screenshot folder: \(ScreenshotWatcher.screenshotFolder.path) — access \(model.screenshotAccess), floating thumbnail \(ScreenshotWatcher.floatingThumbnail ? "on" : "off")",
            "Claude hooks: \(ClaudeHooks.isInstalled ? "connected" : "not connected"); Codex: \(CodexNotify.state)",
            "CLI tools: \(CLIInstaller.isInstalled ? "installed" : "missing"); extension: \(BrowserExtension.installedVersion ?? "not copied")",
            "Last extension event: \(model.lastExtensionEvent.map { "\($0)" } ?? "never")",
        ]
        for permission in Permission.allCases {
            let allowed = permission == .desktop ? model.screenshotAccess == .ok : permission.isGranted
            lines.append("Permission \(permission.title): \(allowed ? "allowed" : "not allowed")")
        }
        let config = (try? String(contentsOf: CoveConfig.fileURL, encoding: .utf8)) ?? "(no config file)"
        lines.append("Config:\n\(config)")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        settingsController.message = "Diagnostics copied to the clipboard."
    }

    // MARK: - Debug routes (CI screenshots)

    private func debugRoute(_ path: String) {
        let parts = path.split(separator: "/").map(String.init) // ["debug", command, arg?]
        let command = parts.count > 1 ? parts[1] : ""
        let arg = parts.count > 2 ? parts[2] : ""
        switch command {
        case "expand":
            model.setExpanded(true)
            model.tab = IslandModel.Tab(rawValue: arg) ?? .home
        case "collapse":
            model.setExpanded(false)
            model.dismissBanner()
        case "settings":
            openSettings(pane: SettingsPane(rawValue: arg) ?? .general)
        case "close-settings":
            settingsWindow?.close()
        case "approval":
            let input: [String: Any] = ["file_path": "/Users/you/hdc/eval.py", "old_string": "acc = evaluate(model)", "new_string": "acc = evaluate(model, seeds=3)\nplot_confusion_matrix(model)"]
            let (action, preview) = AgentBridge.describePermission(tool: "Edit", input: input)
            model.requestApproval(ApprovalRequest(
                sessionID: "claude:ci", project: "hdc-classifier", tool: "Edit", action: action, preview: preview,
                canAlwaysAllow: true, expiresAt: Date().addingTimeInterval(80)
            )) { _ in }
        case "deny-approvals":
            for request in model.approvals { model.resolveApproval(request.id, .deny) }
        case "music":
            nowPlaying?.stop()
            nowPlaying = nil
            model.setNowPlaying(NowPlaying(bundleID: "com.spotify.client", title: "Pink + White", artist: "Frank Ocean",
                                           isPlaying: true, artworkURL: nil, position: 81, duration: 184, readAt: Date()))
        case "schedule":
            model.config.calendar = true
            let now = Date()
            let lecture = CalEvent(id: "1", title: "CPE 3000 Lecture", start: now.addingTimeInterval(-25 * 60), end: now.addingTimeInterval(50 * 60),
                                   location: "Atrium 210", calendar: "Classes", color: Color(hex: 0x5AC8FA), joinURL: nil)
            let lab = CalEvent(id: "2", title: "Swarm robotics lab", start: now.addingTimeInterval(95 * 60), end: now.addingTimeInterval(215 * 60),
                               location: "ICSR Lab", calendar: "Research", color: Color(hex: 0xFF9F0A), joinURL: URL(string: "https://zoom.us/j/1"))
            let due = [
                DueItem(id: "a", title: "Lab 5 report", due: now.addingTimeInterval(20 * 3600), source: "D2L", color: Color(hex: 0xFF453A)),
                DueItem(id: "b", title: "HW 7: Sequential circuits", due: now.addingTimeInterval(3 * 86_400), source: "D2L", color: Color(hex: 0xFF453A)),
            ]
            model.setSchedule(Schedule(events: [lecture, lab], due: due))
        case "hud":
            model.showHUD(.volume, level: 0.62)
        case "future-class":
            model.config.calendar = true
            let start = Date().addingTimeInterval(3 * 3600)
            model.setSchedule(Schedule(events: [CalEvent(id: "f", title: "CPE 3000 Lecture", start: start, end: start.addingTimeInterval(75 * 60),
                                                         location: "Atrium 210", calendar: "Classes", color: Color(hex: 0x5AC8FA), joinURL: nil)]))
        default:
            break
        }
    }

    // MARK: - Demo

    /// Simulates a Claude Code session, including a (fake) permission prompt, so you can see every state.
    /// Nothing is sent anywhere.
    private func runDemo() {
        let id = "claude:demo"
        let project = "hdc-classifier"
        model.agentStarted(id: id, agent: .claude, title: project, detail: "Add a confusion-matrix plot to eval.py", ownerApp: nil)
        after(2) { $0.agentUpdate(id: id, agent: .claude, title: project, detail: "Reading eval.py") }
        after(4) { model in
            let input: [String: Any] = [
                "command": "python -m pytest tests/ -q && git add eval.py",
                "description": "Run the test suite, then stage eval.py",
            ]
            let (action, preview) = AgentBridge.describePermission(tool: "Bash", input: input)
            let request = ApprovalRequest(
                sessionID: id, project: project, tool: "Bash", action: action, preview: preview,
                canAlwaysAllow: true, expiresAt: Date().addingTimeInterval(model.config.approvalTimeout)
            )
            model.requestApproval(request) { [weak self] decision in
                guard decision != .ask else { return }
                let denied = decision == .deny
                self?.after(2) { $0.agentUpdate(id: id, agent: .claude, title: project, detail: denied ? "Skipping tests, editing eval.py" : "Editing eval.py") }
                self?.after(4.5) {
                    $0.agentFinished(id: id, agent: .claude, title: project,
                                     summary: "Added plot_confusion_matrix() and saved figures/confusion.png." + (denied ? "" : " All 14 tests pass."))
                }
            }
        }
    }

    private func after(_ delay: TimeInterval, _ step: @escaping @MainActor (IslandModel) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let model = self?.model else { return }
                step(model)
            }
        }
    }
}
