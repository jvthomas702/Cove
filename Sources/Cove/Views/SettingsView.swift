import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Backs the Settings window: live permission/connection status plus actions that change the system.
@MainActor
final class SettingsController: ObservableObject {
    let model: IslandModel
    let updater: CoveUpdater
    /// Called with the new config whenever a setting changes (AppDelegate saves and applies it).
    var onConfigChange: ((CoveConfig) -> Void)?
    var onRunDemo: (() -> Void)?
    var onCopyDiagnostics: (() -> Void)?
    /// Re-reads the screenshot folder (shows macOS's access prompt the first time).
    var onRecheckScreenshots: (() -> Void)?
    /// A permission was just requested (so the calendar can re-read right away).
    var onPermissionChanged: ((Permission) -> Void)?

    @Published private(set) var granted: [Permission: Bool] = [:]
    @Published private(set) var cliInstalled = false
    @Published private(set) var claudeHooks = false
    @Published private(set) var claudeCodePresent = false
    @Published private(set) var codex: CodexNotify.State = .notInstalled
    @Published private(set) var extensionVersion: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var instantScreenshots = false
    @Published var message: String?
    /// The calendar link being typed in Settings → Features.
    @Published var feedDraft = ""
    @Published var feedError: String?
    @Published var pane: SettingsPane? = .general

    private var timer: Timer?
    private var modelChanges: AnyCancellable?

    init(model: IslandModel, updater: CoveUpdater? = nil) {
        self.model = model
        self.updater = updater ?? CoveUpdater()
        // Settings panes read config and calendar status from the model, so redraw when it changes.
        modelChanges = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
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
        for permission in Permission.allCases {
            map[permission] = permission == .desktop ? model.screenshotAccess == .ok : permission.isGranted
        }
        if map != granted { granted = map }
        cliInstalled = CLIInstaller.isInstalled
        claudeHooks = ClaudeHooks.isInstalled
        claudeCodePresent = ClaudeHooks.claudeCodeExists
        codex = CodexNotify.state
        extensionVersion = BrowserExtension.installedVersion
        launchAtLogin = SMAppService.mainApp.status == .enabled
        instantScreenshots = !ScreenshotWatcher.floatingThumbnail
    }

    // MARK: Calendar links

    /// Adds every link pasted in the field (several can be pasted at once).
    func addFeeds() {
        let links = feedDraft.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init).filter { !$0.isEmpty }
        guard !links.isEmpty else { return }
        var config = model.config
        for link in links {
            if let problem = Self.feedProblem(link) {
                feedError = problem
                return
            }
            if !config.calendarFeeds.contains(link) { config.calendarFeeds.append(link) }
        }
        feedError = nil
        feedDraft = ""
        onConfigChange?(config)
    }

    func removeFeed(_ link: String) {
        var config = model.config
        config.calendarFeeds.removeAll { $0 == link }
        onConfigChange?(config)
    }

    /// Catches the usual wrong links (the calendar's web page instead of its feed) before fetching.
    nonisolated static func feedProblem(_ link: String) -> String? {
        guard let url = ICSFeedMonitor.normalize(link) else {
            return "That doesn't look like a calendar link. It should start with https:// or webcal://."
        }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        if host.contains("google.com"), !path.hasSuffix(".ics") {
            return "That's a Google Calendar page, not its calendar link. Copy \"Secret address in iCal format\" instead (steps below)."
        }
        if path.contains("/d2l/"), !path.contains("feed") {
            return "That's the D2L calendar page. In D2L Calendar, click Subscribe and copy the link it shows."
        }
        return nil
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
        if permission == .desktop {
            onRecheckScreenshots?()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refresh()
                    if self.model.screenshotAccess != .ok, let url = permission.settingsURL { NSWorkspace.shared.open(url) }
                }
            }
            return
        }
        Task {
            await permission.request()
            refresh()
            onPermissionChanged?(permission)
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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Cove Settings"
        window.titlebarAppearsTransparent = true
        // Black like the island, whatever the system appearance.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = .black
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
            .scrollContentBackground(.hidden)
            .background(Theme.surface)
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
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
        }
        .background(Theme.background)
        .frame(minWidth: 620, minHeight: 520)
        .preferredColorScheme(model.config.islandTheme.colorScheme)
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
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.surface))
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
            ToggleRow(title: "Tell me when a new version is out", detail: "Checks GitHub once a day",
                      isOn: controller.binding(\.checkForUpdates))
        }
        SettingsGroup(title: "The island") {
            Picker("Home widget", selection: controller.binding(\.homeWidget)) {
                ForEach(HomeWidget.allCases.filter { $0 != .ai }, id: \.self) { Text($0.title).tag($0) }
            }
            ToggleRow(title: "Show live AI work beside the notch", detail: "Temporarily shows active AI work, then returns to your sports score",
                      isOn: controller.binding(\.aiWorkInNotch))
            ToggleRow(title: "Open when the pointer rests on the notch",
                      detail: "Off: click the notch to open it", isOn: controller.binding(\.hoverToExpand))
            ToggleRow(title: "Play sounds", detail: "When something finishes, fails or needs you",
                      isOn: controller.binding(\.sounds))
            ToggleRow(title: "Show what Claude is doing", detail: "\"Editing eval.py\", \"$ pytest\" and so on",
                      isOn: controller.binding(\.showToolActivity))
            ToggleRow(title: "Keyboard shortcuts",
                      detail: "⌃⌥Space opens the island. On a permission prompt: ⌃⌥Y allow, ⌃⌥N deny, ⌃⌥A always allow, ⌃⌥T terminal",
                      isOn: controller.binding(\.shortcuts))
        }
        SettingsGroup(title: "Nori") {
            HStack(spacing: 14) {
                Buddy(mood: controller.model.config.buddy ? .happy : .sleepy, size: 44)
                VStack(alignment: .leading, spacing: 10) {
                    ToggleRow(title: "Show Nori", detail: "Reacts when agents and commands work, finish, fail or need you",
                              isOn: controller.binding(\.buddy))
                    ToggleRow(title: "Keep Nori beside the notch when nothing is happening",
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
        SettingsGroup(title: "AI activity",
                      footer: "Open the AI tab to inspect your connected agents. App tracking reads visible window titles and generation controls locally; it needs Accessibility. Keep ChatGPT's chat window open. Browser reply previews can be turned off in the extension.") {
            ToggleRow(title: "Follow the ChatGPT desktop app", isOn: controller.binding(\.desktopAIActivity))
            Text(controller.model.desktopAITrackingStatus).font(.caption).foregroundStyle(.secondary)
            if controller.model.config.desktopAIActivity && !Permission.accessibility.isGranted {
                Button("Allow Accessibility…") { controller.request(.accessibility) }
            }
        }
        SettingsGroup(title: "Sports",
                      footer: "Choose a game in the Sports tab to pin its score and latest play to the Home widget. Selected live games refresh about every 10 seconds; other followed scores refresh each minute. ESPN coverage and delays vary.") {
            ToggleRow(title: "Enable sports", detail: "NBA, NFL and college football", isOn: controller.binding(\.sportsEnabled))
            ToggleRow(title: "College football: Top 25 games only", detail: "At least one ranked team; turn off to browse all FBS games",
                      isOn: controller.binding(\.sportsRankedOnly))
        }
        SettingsGroup(title: "Favorite teams", footer: "Favorites stay visible in the game picker, including unranked college teams. Auto-follow selects your next live or upcoming favorite matchup after the current game ends.") {
            SportsFavoritesPicker(model: controller.model)
            ToggleRow(title: "Automatically follow favorite teams", isOn: controller.binding(\.sportsAutoFollow))
            ToggleRow(title: "Notify when a followed game starts", isOn: controller.binding(\.sportsStartAlerts))
            ToggleRow(title: "Notify about followed score changes", isOn: controller.binding(\.sportsScoreAlerts))
        }
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
        CalendarLinksGroup(controller: controller)
        SettingsGroup(title: "Calendar app") {
            ToggleRow(title: "Also read the Calendar app", detail: "Google, iCloud and Exchange accounts added in System Settings → Internet Accounts",
                      isOn: controller.binding(\.calendar))
            if controller.model.config.calendar {
                CalendarStatusView(status: controller.model.calendarStatus, schedule: controller.model.schedule) {
                    controller.request(.calendars)
                }
            }
        }
        SettingsGroup(title: "Classes and due dates") {
            Picker("Start the countdown", selection: controller.binding(\.countdownMinutes)) {
                Text("15 minutes before").tag(15)
                Text("30 minutes before").tag(30)
                Text("1 hour before").tag(60)
                Text("2 hours before").tag(120)
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
            SwiftUI.Group {
                ToggleRow(title: "Show a banner for new screenshots", detail: "Off by default: captures arrive quietly without changing your tab",
                          isOn: controller.binding(\.screenshotBanners))
                ToggleRow(title: "Instant screenshots", detail: "Hides macOS's floating thumbnail so the shelf gets them right away",
                          isOn: Binding(get: { controller.instantScreenshots }, set: { controller.setInstantScreenshots($0) }))
                ToggleRow(title: "Move screenshots off the Desktop", detail: "Into Pictures › Screenshots",
                          isOn: controller.binding(\.screenshotsMoveOffDesktop))
            }
            .disabled(!controller.model.config.screenshotsToShelf)
            ToggleRow(title: "AirDrop drop zone",
                      detail: "Drag a file onto the notch, then drop it on AirDrop to send it or on Keep to shelve it",
                      isOn: controller.binding(\.airDropDropZone))
            ToggleRow(title: "Keep recent copied text on the shelf",
                      detail: "The last 12 clips, kept in memory only. Skips passwords from password managers",
                      isOn: controller.binding(\.clipboardHistory))
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
            ToggleRow(title: "AirPods and Bluetooth battery", detail: "Levels when they connect, and alerts at 20% and 10%",
                      isOn: controller.binding(\.bluetoothBattery))
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

/// Pasted D2L / Canvas / Google calendar links, each with whether it loaded.
private struct CalendarLinksGroup: View {
    @ObservedObject var controller: SettingsController

    var body: some View {
        SettingsGroup(title: "Calendar links",
                      footer: "Calendar links are private: anyone with one can read that calendar, so Cove keeps them on this Mac and leaves them out of diagnostics.") {
            ForEach(controller.model.config.calendarFeeds, id: \.self) { link in
                FeedRow(link: link, status: controller.model.feedStatuses.first { $0.url == link }) {
                    controller.removeFeed(link)
                }
                Divider()
            }
            HStack(spacing: 8) {
                TextField("Paste a D2L, Canvas or Google Calendar link", text: $controller.feedDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { controller.addFeeds() }
                Button("Add") { controller.addFeeds() }
                    .disabled(controller.feedDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = controller.feedError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                HelpStep(title: "D2L", text: "Open Calendar in D2L, click Subscribe (under the calendar list), choose All Courses and copy the link.") {
                    Button("Open D2L") { NSWorkspace.shared.open(URL(string: "https://kennesaw.view.usg.edu/d2l/home")!) }
                }
                HelpStep(title: "Google", text: "In Google Calendar settings, click your calendar on the left, scroll to Integrate calendar and copy Secret address in iCal format. Do this for each calendar you want.") {
                    Button("Open Google Calendar settings") { NSWorkspace.shared.open(URL(string: "https://calendar.google.com/calendar/r/settings")!) }
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct FeedRow: View {
    let link: String
    let status: FeedStatus?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(status?.name ?? ICSFeedMonitor.normalize(link).map(ICSFeedMonitor.friendlyName) ?? "Calendar link")
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove this calendar link")
        }
    }

    private var symbol: String {
        switch status?.state {
        case .ok: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        default: return "arrow.triangle.2.circlepath"
        }
    }

    private var color: Color {
        switch status?.state {
        case .ok: return .green
        case .failed: return .orange
        default: return .secondary
        }
    }

    private var detail: String {
        switch status?.state {
        case .ok:
            let count = status?.itemCount ?? 0
            let items = count == 0 ? "Nothing coming up" : "\(count) coming up"
            if let fetched = status?.fetchedAt { return "\(items) · updated \(fetched.formatted(.relative(presentation: .named)))" }
            return items
        case .failed(let reason): return reason
        default: return "Loading…"
        }
    }
}

private struct HelpStep<Accessory: View>: View {
    let title: String
    let text: String
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            accessory().controlSize(.small)
        }
    }
}

/// "Cove sees 5 calendars: … Next: CPE 3000 Lecture, tomorrow 9:30 AM" — or what's missing.
private struct CalendarStatusView: View {
    let status: CalendarStatus
    let schedule: Schedule
    let allow: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if status.access != .granted { Button("Allow…", action: allow) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(color.opacity(0.1)))
    }

    private var icon: String { status.access == .granted ? (status.calendars.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") : "calendar.badge.exclamationmark" }
    private var color: Color { status.access == .granted && !status.calendars.isEmpty ? .green : .orange }

    private var headline: String {
        switch status.access {
        case .notDetermined: return "Cove hasn't been allowed to read your calendars yet"
        case .denied: return "Calendar access is off"
        case .granted:
            if status.calendars.isEmpty { return "No calendars found" }
            return "Cove sees \(status.calendars.count) calendar\(status.calendars.count == 1 ? "" : "s"): \(status.calendars.prefix(4).joined(separator: ", "))\(status.calendars.count > 4 ? "…" : "")"
        }
    }

    private var detail: String {
        switch status.access {
        case .notDetermined, .denied:
            return "Click Allow, then turn Cove on under Calendars in System Settings → Privacy & Security."
        case .granted:
            if status.calendars.isEmpty {
                return "Paste your D2L and Google links above, or add your Google account in System Settings → Internet Accounts."
            }
            var parts: [String] = []
            if let next = schedule.currentEvent() {
                parts.append("Now: \(next.title)")
            } else if let next = schedule.upcomingEvent() {
                parts.append("Next: \(next.title), \(next.start.formatted(.relative(presentation: .named)))")
            } else {
                parts.append("No classes or meetings in the next 2 days")
            }
            parts.append("\(status.dueCount) due soon")
            if status.remindersAccess != .granted { parts.append("Reminders not allowed") }
            return parts.joined(separator: " · ")
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
    /// Observed directly so the GitHub Actions status line updates live.
    @ObservedObject private var model: IslandModel

    init(controller: SettingsController) {
        _controller = ObservedObject(wrappedValue: controller)
        _model = ObservedObject(wrappedValue: controller.model)
    }

    var body: some View {
        Text("AI connections").font(.title2.weight(.semibold))
        Text("Connect your coding agents and AI chats to follow their work in the notch.")
            .font(.subheadline).foregroundStyle(.secondary)
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
        SettingsGroup(title: "ChatGPT desktop",
                      footer: "Reads visible generation controls locally. Accessibility is required to follow the desktop app.") {
            ToggleRow(title: "Follow ChatGPT", isOn: controller.binding(\.desktopAIActivity))
            Text(controller.model.desktopAITrackingStatus).font(.caption).foregroundStyle(.secondary)
            if controller.model.config.desktopAIActivity && !Permission.accessibility.isGranted {
                Button("Allow Accessibility…") { controller.request(.accessibility) }
            }
        }
        SettingsGroup(title: "Browser chat tabs",
              footer: "Works in Chrome, Arc, Brave and Edge. Shows live work and reply previews for ChatGPT, Claude and Gemini. After updating Cove, reload the unpacked extension and refresh your chat tabs.") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cove extension")
                    Text(lastHeard).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(controller.model.lastExtensionEvent == nil ? "Set up…" : "Reinstall…") { controller.setUpExtension() }
            }
        }
        SettingsGroup(title: "GitHub Actions",
              footer: "Shows your workflow runs live in the notch and pings when they pass or fail. Signs in with the GitHub CLI; Cove stores no token.") {
            ToggleRow(title: "Watch my CI runs", detail: ciDetail, isOn: controller.binding(\.ciMonitor))
        }
        SettingsGroup(title: "Claude in the cloud",
              footer: "Sessions on claude.ai/code and in Claude projects run on Anthropic's machines, so they can't reach Cove's hooks. Cove finds the pull requests they open on GitHub and shows them opening, running CI and merging. Click one to open its session.") {
            ToggleRow(title: "Show Claude's cloud pull requests",
                      detail: model.cloudStatus.isEmpty ? "Repos you pushed to in the last two days, or the cloudRepos list in config.json" : model.cloudStatus,
                      isOn: controller.binding(\.cloudSessions))
        }
        SettingsGroup(title: "Terminal",
              footer: "cove-run <command> pings you when a long command finishes. cove-notify \"text\" posts anything to the notch.") {
            statusRow(title: "cove-run and cove-notify", connected: controller.cliInstalled, connectTitle: "Install") {
                controller.installCLI()
            }
        }
    }

    private var ciDetail: String {
        switch model.ciStatus {
        case nil: return "Repos you pushed to in the last two days, or the ciRepos list in config.json"
        case .starting?: return "Signing in…"
        case .noCLI?: return "Install the GitHub CLI first: brew install gh, then gh auth login"
        case .signedOut?: return "Run gh auth login in Terminal, then turn this off and on"
        case .watching(let login, let repos)?:
            let names = repos.map { $0.split(separator: "/").last.map(String.init) ?? $0 }
            return repos.isEmpty ? "Signed in as \(login). No recent pushes to watch yet"
                : "Signed in as \(login), watching \(names.prefix(4).joined(separator: ", "))\(repos.count > 4 ? " and \(repos.count - 4) more" : "")"
        case .error(let message)?: return message
        }
    }

    private var lastHeard: String {
        guard let last = controller.model.lastExtensionEvent else { return "Not heard from yet" }
        return "Last heard from " + last.formatted(.relative(presentation: .named))
    }

    private func statusRow(title: String, connected: Bool, connectTitle: String = "Connect", action: @escaping () -> Void) -> some View {
        HStack {
            Circle().fill(connected ? Theme.accent : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
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
        UpdateSettingsGroup(updater: controller.updater)
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


private struct UpdateSettingsGroup: View {
    @ObservedObject var updater: CoveUpdater
    var body: some View {
        SettingsGroup(title: "Updates", footer: updater.status) {
            ToggleRow(title: "Automatically check for updates", isOn: Binding(get: { updater.automaticChecks }, set: { updater.setAutomaticChecks($0) }))
            ToggleRow(title: "Download and install updates automatically", detail: "Install verified updates when Cove is ready to restart",
                      isOn: Binding(get: { updater.automaticDownloads }, set: { updater.setAutomaticDownloads($0) }))
            Button("Check for updates…") { updater.check() }.disabled(!updater.canCheck)
                .accessibilityIdentifier("updates.check")
        }
    }
}
