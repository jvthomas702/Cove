import AppKit
import SwiftUI
import Combine

/// All island state lives here. Everything runs on the main actor.
@MainActor
final class IslandModel: ObservableObject {
    enum Presentation: Equatable { case idle, compact, banner, expanded }
    enum Tab: String { case home, shelf }

    /// What the two "wings" beside the notch show in compact mode, in priority order.
    enum CompactItem: Equatable {
        case attention(AgentKind)
        case running(count: Int, agent: AgentKind)
        case progress(Activity)
        case finished(count: Int, agent: AgentKind, failed: Bool)
        case focus(end: Date)
        case music(NowPlaying)
    }

    // Geometry
    static let wing: CGFloat = 44
    static let ear: CGFloat = 8
    @Published var notchSize = CGSize(width: 190, height: 32)
    @Published var hasHardwareNotch = true

    // State
    @Published var config: CoveConfig
    @Published private(set) var presentation: Presentation = .idle
    @Published private(set) var expanded = false
    @Published var tab: Tab = .home
    @Published private(set) var activities: [Activity] = []
    @Published private(set) var banner: Banner?
    @Published private(set) var history: [Banner] = []
    @Published private(set) var nowPlaying: NowPlaying?
    @Published private(set) var battery: BatteryState?
    @Published private(set) var focusEnd: Date?
    @Published private(set) var focusTotal: TimeInterval = 0
    @Published private(set) var shelf: [URL] = []
    @Published var serverStatus = "Starting…"

    /// Set by the app delegate: (command, bundleID) → sends play/pause/next to Music or Spotify.
    var mediaControl: ((String, String) -> Void)?

    private var queue: [Banner] = []
    private var bannerTimer: Timer?
    private var focusTimer: Timer?
    private var pruneTimer: Timer?
    private var hoverWork: DispatchWorkItem?
    private var isHovering = false
    private var suppressHoverUntilExit = false
    private var isDropTargeted = false
    private var lastAgentSignal: Date?

    private static let terminalApps = [
        "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]

    init(config: CoveConfig) {
        self.config = config
        loadShelf()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
    }

    // MARK: - Sizes

    func size(for p: Presentation) -> CGSize {
        let n = notchSize
        switch p {
        case .idle: return n
        case .compact: return CGSize(width: n.width + Self.wing * 2, height: n.height)
        case .banner: return CGSize(width: max(n.width + 230, 430), height: n.height + 64)
        case .expanded: return CGSize(width: max(n.width + 430, 640), height: n.height + 206)
        }
    }

    var compactItem: CompactItem? {
        if let a = activities.first(where: { $0.state == .attention }) { return .attention(a.agent) }
        let running = activities.filter { $0.state == .running }
        if let first = running.first {
            if running.count == 1, first.progress != nil { return .progress(first) }
            return .running(count: running.count, agent: first.agent)
        }
        let unseen = activities.filter { ($0.state == .done || $0.state == .failed) && !$0.seen }
        if let first = unseen.first {
            return .finished(count: unseen.count, agent: first.agent, failed: unseen.contains { $0.state == .failed })
        }
        if let end = focusEnd { return .focus(end: end) }
        if let np = nowPlaying, np.isPlaying { return .music(np) }
        return nil
    }

    private func recompute() {
        let next: Presentation
        if expanded { next = .expanded }
        else if banner != nil { next = .banner }
        else if compactItem != nil { next = .compact }
        else { next = .idle }
        if next != presentation { presentation = next }
    }

    // MARK: - Hover / expand

    /// Called on every pointer event over the island (cheap; only transitions schedule work).
    func setHovering(_ hovering: Bool) {
        let changed = hovering != isHovering
        isHovering = hovering
        if hovering {
            guard config.hoverToExpand, !expanded, !suppressHoverUntilExit else { return }
            guard changed || hoverWork == nil else { return }
            hoverWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.hoverWork = nil
                    if self.isHovering { self.setExpanded(true) }
                }
            }
            hoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + config.hoverDelay, execute: work)
        } else if changed {
            suppressHoverUntilExit = false
            scheduleCollapse(after: 0.3)
        }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverWork = nil
                guard !self.isHovering, !self.isDropTargeted else { return }
                self.setExpanded(false)
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func setExpanded(_ value: Bool) {
        guard value != expanded else { return }
        expanded = value
        // Closed on purpose (a click) while the pointer is still over it: don't re-open until it leaves.
        if !value && isHovering { suppressHoverUntilExit = true }
        if value {
            // Opening the island shows everything, so pending banners are folded into history.
            bannerTimer?.invalidate()
            bannerTimer = nil
            banner = nil
            queue.removeAll()
        } else {
            markAllSeen()
            if shelf.isEmpty { tab = .home }
        }
        recompute()
    }

    func toggleExpanded() { setExpanded(!expanded) }

    func setDropTargeted(_ targeted: Bool) {
        isDropTargeted = targeted
        if targeted {
            tab = .shelf
            setExpanded(true)
        } else {
            scheduleCollapse(after: 1.2)
        }
    }

    // MARK: - Banners

    func show(_ b: Banner) {
        history.insert(b, at: 0)
        if history.count > 40 { history.removeLast(history.count - 40) }
        playSound(for: b)
        if expanded { return }
        if banner == nil {
            present(b)
        } else if b.style == .attention {
            queue.insert(b, at: 0)
        } else {
            queue.append(b)
        }
        if queue.count > 8, let drop = queue.lastIndex(where: { !$0.sticky }) {
            queue.remove(at: drop)
        }
    }

    private func present(_ b: Banner) {
        banner = b
        recompute()
        bannerTimer?.invalidate()
        bannerTimer = nil
        if !b.sticky {
            bannerTimer = Timer.scheduledTimer(withTimeInterval: config.bannerSeconds, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismissBanner() }
            }
        }
    }

    func dismissBanner() {
        bannerTimer?.invalidate()
        bannerTimer = nil
        if !queue.isEmpty {
            present(queue.removeFirst())
        } else {
            banner = nil
            recompute()
        }
    }

    func tapBanner(_ b: Banner) {
        if let id = b.activityID, let a = activity(id) {
            open(a)
        } else if let url = b.openURL {
            NSWorkspace.shared.open(url)
        } else if let app = b.openApp {
            activateApp(app)
        }
        if banner?.id == b.id { dismissBanner() } else { queue.removeAll { $0.id == b.id } }
    }

    private func dropBanners(forActivity id: String) {
        queue.removeAll { $0.activityID == id && $0.style == .attention }
        if let current = banner, current.activityID == id, current.style == .attention { dismissBanner() }
    }

    private func playSound(for b: Banner) {
        guard config.sounds else { return }
        let name: String?
        switch b.style {
        case .success: name = config.doneSound
        case .attention: name = config.attentionSound
        case .failure: name = "Basso"
        case .info: name = nil // the system already chimed for mirrored notifications
        }
        if let name, let sound = NSSound(named: NSSound.Name(name)) {
            sound.stop()
            sound.play()
        }
    }

    // MARK: - Activities (agents & commands)

    func activity(_ id: String) -> Activity? { activities.first { $0.id == id } }

    private func put(_ a: Activity) {
        if let i = activities.firstIndex(where: { $0.id == a.id }) {
            activities[i] = a
        } else {
            activities.insert(a, at: 0)
        }
        recompute()
    }

    func agentStarted(id: String, agent: AgentKind, title: String, detail: String, ownerApp: String?) {
        let now = Date()
        var a = activity(id) ?? Activity(id: id, agent: agent, title: title, detail: detail, state: .running, startedAt: now, updatedAt: now)
        if !a.isLive { a.startedAt = now }
        a.title = title
        a.detail = detail
        a.state = .running
        a.progress = nil
        a.finishedAt = nil
        a.seen = true
        a.updatedAt = now
        if let ownerApp, ownerApp != Bundle.main.bundleIdentifier { a.ownerApp = ownerApp }
        put(a)
    }

    func agentUpdate(id: String, agent: AgentKind, title: String, detail: String, progress: Double? = nil) {
        let now = Date()
        var a = activity(id) ?? Activity(id: id, agent: agent, title: title, detail: detail, state: .running, startedAt: now, updatedAt: now)
        if a.state == .attention { dropBanners(forActivity: id) }
        if !a.isLive { a.startedAt = now; a.finishedAt = nil; a.seen = true }
        a.state = .running
        a.title = title
        a.detail = detail
        if let progress { a.progress = min(max(progress, 0), 1) }
        a.updatedAt = now
        put(a)
    }

    func agentAttention(id: String, agent: AgentKind, title: String, message: String) {
        let now = Date()
        var a = activity(id) ?? Activity(id: id, agent: agent, title: title, detail: message, state: .attention, startedAt: now, updatedAt: now)
        a.state = .attention
        a.title = title
        a.detail = message
        a.updatedAt = now
        put(a)
        lastAgentSignal = now
        dropBanners(forActivity: id)
        show(Banner(
            title: "\(agent.displayName) needs you · \(title)",
            body: message,
            style: .attention,
            icon: .symbol(agent.symbol, agent.tint),
            sticky: true,
            activityID: id
        ))
    }

    func agentFinished(id: String, agent: AgentKind, title: String, summary: String?, failed: Bool = false) {
        let now = Date()
        var a = activity(id) ?? Activity(id: id, agent: agent, title: title, detail: "", state: .done, startedAt: now, updatedAt: now)
        // Ignore a duplicate of the same outcome (a failure right after "done" still gets through).
        if !a.isLive, let f = a.finishedAt, now.timeIntervalSince(f) < 3, (a.state == .failed) == failed { return }
        let took: TimeInterval? = a.isLive ? now.timeIntervalSince(a.startedAt) : nil
        let summaryText = (summary?.isEmpty == false) ? summary : nil
        dropBanners(forActivity: id)
        a.title = title
        a.state = failed ? .failed : .done
        a.finishedAt = now
        a.updatedAt = now
        a.progress = nil
        a.seen = expanded
        a.detail = summaryText ?? took.map { "Finished in \(formatDuration($0))" } ?? "Finished"
        put(a)
        lastAgentSignal = now
        show(Banner(
            title: failed ? "\(agent.displayName) failed · \(title)" : "\(agent.doneTitle) · \(title)",
            body: a.detail,
            style: failed ? .failure : .success,
            icon: .symbol(failed ? "xmark.circle.fill" : agent.symbol, failed ? Palette.red : agent.tint),
            activityID: id
        ))
    }

    func removeActivity(_ id: String) {
        activities.removeAll { $0.id == id }
        dropBanners(forActivity: id)
        recompute()
    }

    func open(_ a: Activity) {
        markSeen(a.id)
        if let owner = a.ownerApp, activateApp(owner) {
            // jumped back to the terminal / editor that started it
        } else if let terminal = Self.terminalApps.first(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
            activateApp(terminal)
        }
        setExpanded(false)
    }

    /// Brings an app to the front. Uses LaunchServices (like clicking it in the Dock), which works
    /// from a background accessory app even with macOS 14's cooperative activation.
    @discardableResult
    private func activateApp(_ bundleID: String) -> Bool {
        let url = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? AppIcons.url(for: bundleID)
        guard let url else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration, completionHandler: nil)
        return true
    }

    /// Called when you switch apps: focusing the terminal that ran an agent counts as "seen".
    func appActivated(_ bundleID: String) {
        var changed = false
        for i in activities.indices where !activities[i].seen && activities[i].ownerApp == bundleID {
            activities[i].seen = true
            changed = true
        }
        if changed { recompute() }
    }

    private func markSeen(_ id: String) {
        if let i = activities.firstIndex(where: { $0.id == id }) { activities[i].seen = true }
        recompute()
    }

    private func markAllSeen() {
        for i in activities.indices where !activities[i].seen { activities[i].seen = true }
    }

    private func prune() {
        let now = Date()
        activities.removeAll { a in
            switch a.state {
            case .done, .failed:
                return a.seen && now.timeIntervalSince(a.finishedAt ?? now) > 600
            case .running, .attention:
                // Agent sessions that went silent for an hour were probably killed without a Stop event.
                return a.agent != .command && now.timeIntervalSince(a.updatedAt) > 3600
            }
        }
        if activities.count > 12 { activities = Array(activities.prefix(12)) }
        recompute()
    }

    // MARK: - Generic events (POST /event, cove-notify, cove-run)

    func ingest(_ e: CoveEvent) {
        let kind = (e.kind ?? "info").lowercased()
        let agent = AgentKind(rawValue: (e.source ?? "custom").lowercased()) ?? .custom
        let body = e.body ?? ""
        switch kind {
        case "running", "progress", "start", "started":
            let id = e.id ?? "event:\(e.title)"
            if activity(id) == nil {
                agentStarted(id: id, agent: agent, title: e.title, detail: body, ownerApp: nil)
            }
            agentUpdate(id: id, agent: agent, title: e.title, detail: body, progress: e.progress)
        case "done", "success", "finished", "complete":
            if let id = e.id, activity(id) != nil {
                agentFinished(id: id, agent: activity(id)?.agent ?? agent, title: e.title, summary: body)
            } else {
                show(Banner(title: e.title, body: body, style: .success,
                            icon: .symbol(agent == .custom ? "checkmark.circle.fill" : agent.symbol, agent == .custom ? Palette.green : agent.tint),
                            sticky: e.sticky ?? false))
            }
        case "error", "failed", "failure":
            if let id = e.id, activity(id) != nil {
                agentFinished(id: id, agent: activity(id)?.agent ?? agent, title: e.title, summary: body, failed: true)
            } else {
                show(Banner(title: e.title, body: body, style: .failure, icon: .symbol("xmark.octagon.fill", Palette.red), sticky: e.sticky ?? false))
            }
        case "attention", "waiting", "input":
            if let id = e.id {
                agentAttention(id: id, agent: agent, title: e.title, message: body)
            } else {
                show(Banner(title: e.title, body: body, style: .attention, icon: .symbol("exclamationmark.bubble.fill", Palette.amber), sticky: e.sticky ?? true))
            }
        case "clear", "remove", "end":
            if let id = e.id { removeActivity(id) }
        default:
            show(Banner(title: e.title, body: body, style: .info, icon: .symbol("bell.fill", Palette.blue), sticky: e.sticky ?? false))
        }
    }

    // MARK: - Mirrored macOS notifications

    func mirrored(_ item: NotificationMirror.Item) {
        let app = item.appID
        if app.caseInsensitiveCompare(Bundle.main.bundleIdentifier ?? "") == .orderedSame { return }
        if config.ignoreApps.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) { return }
        let text = "\(item.title) \(item.subtitle) \(item.body)"
        // Terminals also post a system notification when Claude/Codex finish; we already showed our own.
        if let last = lastAgentSignal, Date().timeIntervalSince(last) < 10,
           text.range(of: "claude", options: .caseInsensitive) != nil || text.range(of: "codex", options: .caseInsensitive) != nil {
            return
        }
        let hot = config.highlightKeywords.contains { !$0.isEmpty && text.range(of: $0, options: .caseInsensitive) != nil }
        let title = item.title.isEmpty ? AppIcons.name(for: app) : item.title
        let body = [item.subtitle, item.body].filter { !$0.isEmpty }.joined(separator: " — ")
        show(Banner(title: title, body: body, style: hot ? .attention : .info, icon: .app(app), sticky: hot, openApp: app))
    }

    func notificationAccessDenied() {
        show(Banner(
            title: "Allow Full Disk Access to mirror notifications",
            body: "Click to open Settings, add Cove, then relaunch it.",
            style: .attention,
            icon: .symbol("lock.shield.fill", Palette.amber),
            sticky: true,
            openURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        ))
    }

    // MARK: - Media

    func setNowPlaying(_ np: NowPlaying?) {
        guard np != nowPlaying else { return }
        nowPlaying = np
        recompute()
    }

    func media(_ command: String) {
        guard let np = nowPlaying else { return }
        mediaControl?(command, np.bundleID)
    }

    // MARK: - Battery

    func setBattery(_ state: BatteryState?) {
        let old = battery
        battery = state
        guard config.batteryAlerts, let state, let old else { return }
        if state.pluggedIn && !old.pluggedIn {
            show(Banner(title: "Charging", body: "\(state.percent)%", style: .info, icon: .symbol("bolt.fill", Palette.green)))
        } else if !state.pluggedIn {
            for threshold in [10, 20] where state.percent <= threshold && old.percent > threshold {
                show(Banner(title: "Battery low", body: "\(state.percent)% remaining", style: .attention,
                            icon: .symbol("battery.25", Palette.red), sticky: threshold == 10))
                break
            }
        }
    }

    // MARK: - Focus timer

    func startFocus(minutes: Int) {
        focusTimer?.invalidate()
        let total = TimeInterval(minutes * 60)
        focusTotal = total
        focusEnd = Date().addingTimeInterval(total)
        focusTimer = Timer.scheduledTimer(withTimeInterval: total, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishFocus() }
        }
        recompute()
    }

    func stopFocus() {
        focusTimer?.invalidate()
        focusTimer = nil
        focusEnd = nil
        recompute()
    }

    private func finishFocus() {
        let minutes = Int(focusTotal / 60)
        stopFocus()
        show(Banner(title: "Focus session done", body: "\(minutes) minutes — take a break.", style: .success,
                    icon: .symbol("timer", Palette.green), sticky: true))
    }

    // MARK: - Shelf

    func receiveDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in self?.addToShelf([url]) }
            }
        }
    }

    func addToShelf(_ urls: [URL]) {
        for url in urls where !shelf.contains(url) { shelf.append(url) }
        if shelf.count > 24 { shelf.removeFirst(shelf.count - 24) }
        saveShelf()
    }

    func removeFromShelf(_ url: URL) {
        shelf.removeAll { $0 == url }
        saveShelf()
    }

    func clearShelf() {
        shelf.removeAll()
        saveShelf()
    }

    private func saveShelf() {
        UserDefaults.standard.set(shelf.map(\.path), forKey: "shelf")
    }

    private func loadShelf() {
        let paths = UserDefaults.standard.stringArray(forKey: "shelf") ?? []
        shelf = paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
