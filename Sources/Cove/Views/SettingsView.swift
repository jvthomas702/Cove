import AppKit
import ServiceManagement
import SwiftUI

/// Backs the Settings window: live permission/connection status plus actions that change the system.
@MainActor
final class SettingsController: ObservableObject {
    let model: IslandModel
    /// Called with the new config whenever a setting changes (AppDelegate saves and applies it).
    var onConfigChange: ((CoveConfig) -> Void)?
    var onRunDemo: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?

    @Published private(set) var granted: [Permission: Bool] = [:]
    @Published private(set) var cliInstalled = false
    @Published private(set) var claudeHooks = false
    @Published private(set) var claudeCodePresent = false
    @Published private(set) var codex: CodexNotify.State = .notInstalled
    @Published private(set) var extensionVersion: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var instantScreenshots = false
    @Published var message: String?
    @Published var pane: SettingsPane? = .general

    private var timer: Timer?

    init(model: IslandModel) {
        self.model = model
        refresh()
    }

    func startRefreshing() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopRefreshing() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        var map: [Permission: Bool] = [:]
        for permission in Permission.allCases { map[permission] = permission.isGranted }
        if map != granted { granted = map }
        cliInstalled = CLIInstaller.isInstalled
        claudeHooks = ClaudeHooks.isInstalled
        claudeCodePresent = ClaudeHooks.claudeCodeExists
        codex = CodexNotify.state
        extensionVersion = BrowserExtension.installedVersion
        launchAtLogin = SMAppService.mainApp.status == .enabled
        instantScreenshots = !ScreenshotWatcher.floatingThumbnail
    }

    // MARK: Config binding

    func binding<T>(_ keyPath: WritableKeyPath<CoveConfig, T>) -> Binding<T> {
        Binding(
            get: { self.model.config[keyPath: keyPath] },
            set: { newValue in
                var config = self.model.config
                config[keyPath: keyPath] = newValue
                self.onConfigChange?(config)
            }
        )
    }

    // MARK: Actions

    func setLaunchAtLogin(_ on: Bool) {
        attempt {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        }
    }

    func setInstantScreenshots(_ on: Bool) {
        ScreenshotWatcher.setFloatingThumbnail(!on)
        refresh()
    }

    func connectClaude(_ on: Bool) {
        attempt {
            if on && !CLIInstaller.isInstalled { try CLIInstaller.install() }
            try ClaudeHooks.set(installed: on)
            if on { message = "Connected. Start a new Claude Code session to use it." }
        }
    }

    func connectCodex(_ on: Bool) {
        attempt {
            if on && !CLIInstaller.isInstalled { try CLIInstaller.install() }
            if on { try CodexNotify.connect() } else { try CodexNotify.disconnect() }
        }
    }

    func installCLI() {
        attempt {
            try CLIInstaller.install()
            message = "Installed cove-run and cove-notify. Open a new terminal window to use them."
        }
    }

    func setUpExtension() {
        BrowserExtension.openSetup()
        message = "In the extensions page: turn on Developer mode → Load unpacked → press ⌘⇧G and paste (the folder path is on your clipboard)."
        refresh()
    }

    func request(_ permission: Permission) {
        Task {
            await permission.request()
            refresh()
        }
    }

    private func attempt(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            message = error.localizedDescription
        }
        refresh()
    }
}

// MARK: - Window

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let controller: SettingsController

    init(controller: SettingsController) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cove Settings"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsView(controller: controller))
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(pane: SettingsPane = .general) {
        controller.startRefreshing()
        controller.pane = pane
        // An accessory app has to become a regular app briefly to bring a window to the front.
        NSApp.setActivationPolicy(.regular)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        controller.stopRefreshing()
        NSApp.setActivationPolicy(.accessory)
    }
}

// MARK: - Views

enum SettingsPane: String, CaseIterable, Identifiable {
        case general, features, permissions, connections, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .features: return "Features"
            case .permissions: return "Permissions"
            case .connections: return "Connections"
            case .about: return "About"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .features: return "square.grid.2x2"
            case .permissions: return "lock.shield"
            case .connections: return "point.3.connected.trianglepath.dotted"
            case .about: return "info.circle"
            }
        }
}

struct SettingsView: View {
    @ObservedObject var controller: SettingsController
    @ObservedObject private var model: IslandModel

    init(controller: SettingsController) {
        _controller = ObservedObject(wrappedValue: controller)
        _model = ObservedObject(wrappedValue: controller.model)
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $controller.pane) { pane in
                Label(pane.title, systemImage: pane.symbol)
                    .badge(pane == .permissions ? missingPermissions : 0)
                    .tag(pane)
            }
            .navigationSplitViewColumnWidth(170)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let message = controller.message {
                        MessageBar(text: message) { controller.message = nil }
                    }
                    switch controller.pane ?? .general {
                    case .general: GeneralPane(controller: controller)
                    case .features: FeaturesPane(controller: controller)
                    case .permissions: PermissionsPane(controller: controller)
                    case .connections: ConnectionsPane(controller: controller)
                    case .about: AboutPane(controller: controller)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 620, minHeight: 520)
    }

    private var missingPermissions: Int {
        controller.granted.values.filter { !$0 }.count
    }
}

private struct MessageBar: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill").foregroundStyle(.blue)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.blue.opacity(0.12)))
    }
}

/// A titled group of rows, like System Settings.
private struct SettingsGroup<Content: View>: View {
    let title: String
    var footer: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct ToggleRow: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .toggleStyle(.switch)
    }
}

// MARK: General

private struct GeneralPane: View {
    @ObservedObject var controller: SettingsController

    var body: some View {
        SettingsGroup(title: "Startup") {
            ToggleRow(title: "Open Cove when you log in",
                      isOn: Binding(get: { controller.launchAtLogin }, set: { controller.setLaunchAtLogin($0) }))
        }
        SettingsGroup(title: "The island") {
            ToggleRow(title: "Open when the pointer rests on the notch",
                      detail: "Off: click the notch to open it", isOn: controller.binding(\.hoverToExpand))
            ToggleRow(title: "Play sounds", detail: "When something finishes, fails or needs you",
                      isOn: controller.binding(\.sounds))
            ToggleRow(title: "Show what Claude is doing", detail: "\"Editing eval.py\", \"$ pytest\" and so on",
                      isOn: controller.binding(\.showToolActivity))
        }
        SettingsGroup(title: "Pip") {
            HStack(spacing: 14) {
                Buddy(mood: controller.model.config.buddy ? .happy : .sleepy, size: 44)
                VStack(alignment: .leading, spacing: 10) {
                    ToggleRow(title: "Show Pip", detail: "Reacts when agents and commands work, finish, fail or need you",
                              isOn: controller.binding(\.buddy))
                    ToggleRow(title: "Keep Pip beside the notch when nothing is happening",
                              isOn: controller.binding(\.buddyAlwaysVisible))
                        .disabled(!controller.model.config.buddy)
                }
            }
        }
    }
}

// MARK: Features

private struct FeaturesPane: View {
    @ObservedObject var controller: SettingsController

    var body: some View {
        SettingsGroup(title: "Claude Code permission prompts",
              footer: "Smart shows prompts in the notch unless Claude's terminal is in front or you're away from the Mac. Unanswered prompts go back to the terminal.") {
            Picker("Answer prompts from the notch", selection: controller.binding(\.approvals)) {
                Text("Smart").tag("smart")
                Text("Always").tag("always")
                Text("Never").tag("off")
            }
            .pickerStyle(.segmented)
            Stepper(value: controller.binding(\.approvalTimeout), in: 15...95, step: 5) {
                Text("Hand back to the terminal after \(Int(controller.model.config.approvalTimeout)) seconds")
            }
        }
        SettingsGroup(title: "Calendar") {
            ToggleRow(title: "Classes and meetings", detail: "From the Calendar app, including Google and iCloud calendars",
                      isOn: controller.binding(\.calendar))
            Picker("Start the countdown", selection: controller.binding(\.countdownMinutes)) {
                Text("15 minutes before").tag(15)
                Text("30 minutes before").tag(30)
                Text("1 hour before").tag(60)
            }
            Picker("Heads-up banner", selection: controller.binding(\.meetingAlertMinutes)) {
                Text("Off").tag(0)
                Text("5 minutes before").tag(5)
                Text("10 minutes before").tag(10)
                Text("15 minutes before").tag(15)
            }
            ToggleRow(title: "Banner when an event starts", isOn: controller.binding(\.eventStartAlert))
            Picker("Due soon looks ahead", selection: controller.binding(\.dueLookaheadDays)) {
                Text("3 days").tag(3)
                Text("1 week").tag(7)
                Text("2 weeks").tag(14)
            }
        }
        SettingsGroup(title: "Screenshots",
              footer: "macOS's floating thumbnail holds each screenshot for about 5 seconds before saving it. Turn on instant screenshots to skip it.") {
            ToggleRow(title: "Put new screenshots on the shelf", isOn: controller.binding(\.screenshotsToShelf))
            ToggleRow(title: "Instant screenshots", detail: "Hides macOS's floating thumbnail so the shelf gets them right away",
                      isOn: Binding(get: { controller.instantScreenshots }, set: { controller.setInstantScreenshots($0) }))
            ToggleRow(title: "Move screenshots off the Desktop", detail: "Into Pictures › Screenshots",
                      isOn: controller.binding(\.screenshotsMoveOffDesktop))
        }
        SettingsGroup(title: "Volume and brightness") {
            Picker("Show changes", selection: controller.binding(\.hud)) {
                Text("In the notch").tag("replace")
                Text("Alongside macOS").tag("passive")
                Text("Off").tag("off")
            }
            .pickerStyle(.segmented)
        }
        SettingsGroup(title: "Notifications") {
            ToggleRow(title: "Show notifications from other apps", detail: "Needs Full Disk Access",
                      isOn: controller.binding(\.mirrorNotifications))
            ToggleRow(title: "Battery alerts", detail: "Charging, 20% and 10%", isOn: controller.binding(\.batteryAlerts))
            VStack(alignment: .leading, spacing: 4) {
                Text("Highlight notifications that mention")
                TextField("interview, offer, deadline", text: Binding(
                    get: { controller.model.config.highlightKeywords.joined(separator: ", ") },
                    set: { text in
                        var config = controller.model.config
                        config.highlightKeywords = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        controller.onConfigChange?(config)
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
    }
}

// MARK: Permissions

private struct PermissionsPane: View {
    @ObservedObject var controller: SettingsController

    var body: some View {
        Text("Cove only asks for what each feature needs. Everything stays on this Mac.")
            .foregroundStyle(.secondary)
        SettingsGroup(title: "Access") {
            ForEach(Permission.allCases) { permission in
                HStack(spacing: 12) {
                    Image(systemName: permission.symbol)
                        .frame(width: 22)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(permission.title)
                        Text(permission.reason).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if controller.granted[permission] == true {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    } else {
                        Button("Allow…") { controller.request(permission) }
                    }
                }
                if permission != Permission.allCases.last { Divider() }
            }
        }
        Text("After turning on Full Disk Access or Accessibility, quit Cove from the menu bar and open it again.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

// MARK: Connections

private struct ConnectionsPane: View {
    @ObservedObject var controller: SettingsController

    var body: some View {
        SettingsGroup(title: "Claude Code",
              footer: controller.claudeCodePresent ? "Adds hooks to ~/.claude/settings.json (a backup is kept). Start a new session afterwards." : "Claude Code isn't set up on this Mac yet.") {
            statusRow(title: "Agent pings and permission prompts", connected: controller.claudeHooks) {
                controller.connectClaude(!controller.claudeHooks)
            }
        }
        SettingsGroup(title: "Codex") {
            switch controller.codex {
            case .notInstalled:
                Text("Codex isn't set up on this Mac.").foregroundStyle(.secondary)
            case .otherNotifyProgram:
                Text("Codex already has a notify program in ~/.codex/config.toml. Replace it with cove-codex-notify to connect.")
                    .foregroundStyle(.secondary)
            case .connected, .disconnected:
                statusRow(title: "Turn-finished pings", connected: controller.codex == .connected) {
                    controller.connectCodex(controller.codex != .connected)
                }
            }
        }
        SettingsGroup(title: "Browser chat tabs",
              footer: "Works in Chrome, Arc, Brave and Edge. Pings when ChatGPT, Claude or Gemini finishes answering in a background tab.") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cove extension")
                    Text(lastHeard).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(controller.model.lastExtensionEvent == nil ? "Set up…" : "Reinstall…") { controller.setUpExtension() }
            }
        }
        SettingsGroup(title: "Terminal",
              footer: "cove-run <command> pings you when a long command finishes. cove-notify \"text\" posts anything to the notch.") {
            statusRow(title: "cove-run and cove-notify", connected: controller.cliInstalled, connectTitle: "Install") {
                controller.installCLI()
            }
        }
    }

    private var lastHeard: String {
        guard let last = controller.model.lastExtensionEvent else { return "Not heard from yet" }
        return "Last heard from " + last.formatted(.relative(presentation: .named))
    }

    private func statusRow(title: String, connected: Bool, connectTitle: String = "Connect", action: @escaping () -> Void) -> some View {
        HStack {
            Circle().fill(connected ? Color.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
            Text(title)
            Spacer()
            if connected && connectTitle == "Install" {
                Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button(connected ? "Disconnect" : connectTitle, action: action)
            }
        }
    }
}

// MARK: About

private struct AboutPane: View {
    @ObservedObject var controller: SettingsController

    var body: some View {
        HStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
            VStack(alignment: .leading, spacing: 4) {
                Text("Cove").font(.title.weight(.semibold))
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                    .foregroundStyle(.secondary)
                Text(controller.model.serverStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
        SettingsGroup(title: "Help") {
            HStack {
                Button("Run the demo") { controller.onRunDemo?() }
                Button("Copy diagnostics") { controller.onCopyDiagnostics?() }
                Button("Open settings file") { NSWorkspace.shared.open(CoveConfig.fileURL) }
            }
            Text("Copy diagnostics puts a short report on your clipboard (versions, permissions, connections) to paste into a bug report. It contains no notification or chat content.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
