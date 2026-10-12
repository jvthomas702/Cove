import AppKit
import ServiceManagement

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
    private let screenshots = ScreenshotWatcher()
    private let volume = VolumeController()
    private let mediaKeys = MediaKeyTap()
    private var trustTimer: Timer?
    private var statusItem: NSStatusItem!
    private var statusLine: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var workspaceObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = CoveConfig.load()
        model = IslandModel(config: config)
        windowController = NotchWindowController(model: model)
        agents = AgentBridge(model: model)

        startServer(port: config.port)
        startMedia(apps: config.mediaApps)
        if config.mirrorNotifications { startMirror() }

        battery.onChange = { [weak self] state in self?.model.setBattery(state) }
        battery.start()

        if config.calendar { startCalendar(config) }
        screenshots.onNew = { [weak self] urls in self?.model.addScreenshots(urls) }
        screenshots.start()
        startHUD(mode: config.hud)

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let bundleID = app?.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.model.appActivated(bundleID) }
        }

        buildStatusItem()
        model.show(Banner(
            title: "Cove is running",
            body: "Hover the notch to open it. Agents report in on port \(config.port).",
            style: .success,
            icon: .symbol("sparkles", Palette.claude)
        ))
    }

    func applicationWillTerminate(_ notification: Notification) {
        server?.stop()
        mirror?.stop()
        nowPlaying?.stop()
        battery.stop()
        calendar?.stop()
        screenshots.stop()
        volume.stop()
        mediaKeys.stop()
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
            self?.statusLine?.title = "Cove — \(text)"
        }
        do {
            try server.start()
            self.server = server
        } catch {
            model.serverStatus = "port \(port) unavailable"
            model.show(Banner(
                title: "Couldn't start on port \(port)",
                body: "Another app is using it. Change \"port\" in ~/.config/cove/config.json.",
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
        switch (exchange.method, exchange.path) {
        case ("GET", "/health"):
            exchange.respond(200, #"{"ok":true,"app":"cove"}"#)
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

    // MARK: - Calendar

    private func startCalendar(_ config: CoveConfig) {
        let monitor = CalendarMonitor(config: config)
        monitor.onUpdate = { [weak self] schedule in self?.model.setSchedule(schedule) }
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

    // MARK: - Volume & brightness HUD

    private func startHUD(mode: String) {
        let mode = mode.lowercased()
        guard mode != "off" else { return }
        volume.onChange = { [weak self] level, muted in
            self?.model.showHUD(.volume, level: Double(level), muted: muted)
        }
        volume.start()
        guard mode == "replace" else { return }

        mediaKeys.handler = { [weak self] key, isDown, _, fine in
            self?.handleMediaKey(key, isDown: isDown, fine: fine) ?? false
        }
        if MediaKeyTap.isTrusted {
            mediaKeys.start()
        } else {
            MediaKeyTap.requestTrust()
            // Start the tap as soon as Accessibility is granted; until then the passive HUD still works.
            trustTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard MediaKeyTap.isTrusted else { return }
                    timer.invalidate()
                    self?.mediaKeys.start()
                }
            }
        }
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

    private func startMedia(apps: [String]) {
        let monitor = NowPlayingMonitor(apps: apps)
        monitor.onUpdate = { [weak self] np in self?.model.setNowPlaying(np) }
        monitor.onArtwork = { [weak self] key, data in self?.model.setArtwork(data, forTrack: key) }
        model.mediaControl = { [weak monitor] command, bundleID in monitor?.send(command, to: bundleID) }
        monitor.start()
        nowPlaying = monitor
    }

    private func startMirror() {
        let mirror = NotificationMirror()
        mirror.onItems = { [weak self] items in
            for item in items { self?.model.mirrored(item) }
        }
        mirror.onAccessDenied = { [weak self] in self?.model.notificationAccessDenied() }
        mirror.start()
        self.mirror = mirror
    }

    // MARK: - Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.menuBarGlyph()
        statusItem.button?.toolTip = "Cove"

        let menu = NSMenu()
        statusLine = NSMenuItem(title: "Cove — \(model.serverStatus)", action: nil, keyEquivalent: "")
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        addItem(to: menu, "Run demo", #selector(runDemo))
        addItem(to: menu, "Send test notification", #selector(sendTest))
        menu.addItem(.separator())
        addItem(to: menu, "Open config…", #selector(openConfig), key: ",")
        addItem(to: menu, "Reload config", #selector(reloadConfig))
        addItem(to: menu, "Grant Full Disk Access…", #selector(openFullDiskAccess))
        loginItem = addItem(to: menu, "Launch at login", #selector(toggleLoginItem))
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
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

    @objc private func sendTest() {
        model.ingest(CoveEvent(title: "Hello from Cove 👋", body: "This is what a notification looks like.", kind: "info"))
    }

    @objc private func openConfig() {
        _ = CoveConfig.load() // makes sure the file exists
        NSWorkspace.shared.open(CoveConfig.fileURL)
    }

    @objc private func reloadConfig() {
        model.config = CoveConfig.load()
        calendar?.update(config: model.config)
        model.show(Banner(title: "Config reloaded", body: "Port changes apply after a restart.", style: .info,
                          icon: .symbol("arrow.clockwise", Palette.blue)))
    }

    @objc private func openFullDiskAccess() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            model.show(Banner(title: "Couldn't change login item", body: error.localizedDescription, style: .failure,
                              icon: .symbol("exclamationmark.triangle.fill", Palette.red)))
        }
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    /// Simulates a Claude Code session, including a (fake) permission prompt, so you can see every state.
    /// Nothing is sent anywhere.
    @objc private func runDemo() {
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
