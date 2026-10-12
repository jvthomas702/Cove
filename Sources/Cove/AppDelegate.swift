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
    }

    // MARK: - Services

    private func startServer(port: UInt16) {
        let server = EventServer(port: port) { [weak self] method, path, body in
            self?.route(method: method, path: path, body: body) ?? (503, #"{"error":"shutting down"}"#)
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

    private func route(method: String, path: String, body: Data) -> (Int, String) {
        let ok = (200, #"{"ok":true}"#)
        switch (method, path) {
        case ("GET", "/health"):
            return (200, #"{"ok":true,"app":"cove"}"#)
        case ("POST", "/event"):
            guard let event = try? JSONDecoder().decode(CoveEvent.self, from: body) else {
                return (400, #"{"error":"expected JSON with at least a \"title\""}"#)
            }
            model.ingest(event)
            return ok
        case ("POST", "/hook/claude"):
            agents.handleClaude(body)
            return ok
        case ("POST", "/hook/codex"):
            agents.handleCodex(body)
            return ok
        default:
            return (404, #"{"error":"not found"}"#)
        }
    }

    private func startMedia(apps: [String]) {
        let monitor = NowPlayingMonitor(apps: apps)
        monitor.onUpdate = { [weak self] np in self?.model.setNowPlaying(np) }
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
        statusItem.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Cove")
        statusItem.button?.image?.isTemplate = true

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

    /// Simulates a Claude Code session so you can see every state without wiring anything up.
    @objc private func runDemo() {
        let id = "claude:demo"
        let steps: [(TimeInterval, () -> Void)] = [
            (0.0, { [weak self] in self?.model.agentStarted(id: id, agent: .claude, title: "hdc-classifier", detail: "Add a confusion-matrix plot to eval.py", ownerApp: nil) }),
            (2.0, { [weak self] in self?.model.agentUpdate(id: id, agent: .claude, title: "hdc-classifier", detail: "Reading eval.py") }),
            (4.0, { [weak self] in self?.model.agentUpdate(id: id, agent: .claude, title: "hdc-classifier", detail: "$ python -m pytest tests/") }),
            (6.5, { [weak self] in self?.model.agentAttention(id: id, agent: .claude, title: "hdc-classifier", message: "Claude needs your permission to use Bash") }),
            (10.0, { [weak self] in self?.model.agentUpdate(id: id, agent: .claude, title: "hdc-classifier", detail: "Editing eval.py") }),
            (13.0, { [weak self] in self?.model.agentFinished(id: id, agent: .claude, title: "hdc-classifier", summary: "Added plot_confusion_matrix() and saved figures/confusion.png. All 14 tests pass.") }),
        ]
        for (delay, step) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { step() }
            }
        }
    }
}
