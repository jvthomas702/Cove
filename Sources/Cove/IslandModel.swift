import AppKit
import SwiftUI
import Combine

/// All island state lives here. Everything runs on the main actor.
@MainActor
final class IslandModel: ObservableObject {
    enum Presentation: Equatable { case idle, compact, banner, expanded, approval }
    enum Tab: String, CaseIterable { case home, schedule, shelf }

    /// What the two "wings" beside the notch show in compact mode, in priority order.
    enum CompactItem: Equatable {
        case hud(HUDState)
        case attention(AgentKind)
        case event(CalEvent)      // starting soon
        case ongoing(CalEvent)    // happening now
        case running(count: Int, agent: AgentKind)
        case progress(Activity)
        case finished(count: Int, agent: AgentKind, failed: Bool)
        case focus(end: Date)
        case music(NowPlaying)
    }

    // Geometry
    static let wing: CGFloat = 44
    static let ear: CGFloat = 8
    @Published var notchSize = CGSize(width: 190, height: 32) {
        didSet { recompute() }
    }
    /// The island's current size; the window follows this.
    @Published private(set) var currentSize = CGSize(width: 190, height: 32)
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
    /// Album art for the current track and the color pulled from it (tints the music UI).
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color?
    /// A file drag is hovering over the island.
    @Published private(set) var isDropTargeted = false
    @Published private(set) var battery: BatteryState?
    @Published private(set) var focusEnd: Date?
    @Published private(set) var focusTotal: TimeInterval = 0
    @Published private(set) var shelf: [URL] = []
    @Published private(set) var schedule = Schedule()
    @Published private(set) var hud: HUDState?
    @Published private(set) var approvals: [ApprovalRequest] = []
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
    private var artworkKey: String?
    private var lastAgentSignal: Date?
    private var hudTimer: Timer?
    private var clockTimer: Timer?
    private var lastAlertCheck = Date()
    private var approvalReplies: [UUID: @MainActor (ApprovalDecision) -> Void] = [:]

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
        // Drives the calendar countdown and heads-up alerts.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clockTick() }
        }
    }

    // MARK: - Sizes

    func size(for p: Presentation) -> CGSize {
        let n = notchSize
        switch p {
        case .idle: return n
        case .compact: return CGSize(width: n.width + compactWing * 2, height: n.height)
        case .banner: return CGSize(width: max(n.width + 250, 440), height: n.height + 72)
        case .expanded: return CGSize(width: max(n.width + 450, 660), height: n.height + 252)
        case .approval:
            // Grows with the preview (a one-line command vs. an 8-line diff).
            let lines = CGFloat(max(approvals.first?.preview.lines.count ?? 1, 1))
            return CGSize(width: max(n.width + 420, 620), height: n.height + min(134 + lines * 17, 280))
        }
    }

    /// Width of each wing in compact mode. Wider for things that need words (a class name, a level bar).
    var compactWing: CGFloat {
        switch compactItem {
        case .event?, .ongoing?: return 112
        case .hud?: return 74
        default: return Self.wing
        }
    }

    /// The next event worth a countdown, if it starts within `countdownMinutes` (or started < 5 min ago).
    var countdownEvent: CalEvent? {
        guard config.calendar, let next = schedule.nextEvent() else { return nil }
        let minutes = next.start.timeIntervalSinceNow / 60
        return minutes <= Double(config.countdownMinutes) ? next : nil
    }

    var compactItem: CompactItem? {
        if let hud { return .hud(hud) }
        if let a = activities.first(where: { $0.state == .attention }) { return .attention(a.agent) }
        // A class or meeting about to start beats background work.
        if let event = countdownEvent, event.start.timeIntervalSinceNow <= Double(max(config.meetingAlertMinutes, 5)) * 60 {
            return .event(event)
        }
        let running = activities.filter { $0.state == .running }
        if let first = running.first {
            if running.count == 1, first.progress != nil { return .progress(first) }
            return .running(count: running.count, agent: first.agent)
        }
        let unseen = activities.filter { ($0.state == .done || $0.state == .failed) && !$0.seen }
        if let first = unseen.first {
            return .finished(count: unseen.count, agent: first.agent, failed: unseen.contains { $0.state == .failed })
        }
        if config.calendar, let now = schedule.currentEvent() { return .ongoing(now) }
        if let event = countdownEvent { return .event(event) }
        if let end = focusEnd { return .focus(end: end) }
        if let np = nowPlaying, np.isPlaying { return .music(np) }
        return nil
    }

    private func recompute() {
        let next: Presentation
        if !approvals.isEmpty { next = .approval }
        else if expanded { next = .expanded }
        else if hud != nil { next = .compact }
        else if banner != nil { next = .banner }
        else if compactItem != nil { next = .compact }
        else { next = .idle }
        if next != presentation { presentation = next }
        let newSize = self.size(for: next)
        if newSize != currentSize { currentSize = newSize }
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
            if tab != .shelf || shelf.isEmpty { tab = .home }
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
            bannerTimer = Timer.scheduledTimer(withTimeInterval: b.duration ?? config.bannerSeconds, repeats: false) { [weak self] _ in
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
        if b.showsShelf {
            tab = .shelf
            setExpanded(true)
        } else if let id = b.activityID, let a = activity(id) {
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
            icon: config.buddy ? .buddy(.alert, agent) : .symbol(agent.symbol, agent.tint),
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
            icon: config.buddy
                ? .buddy(failed ? .sad : .happy, agent)
                : .symbol(failed ? "xmark.circle.fill" : agent.symbol, failed ? Palette.red : agent.tint),
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
                let icon: BannerIcon = config.buddy
                    ? .buddy(.happy, agent == .custom ? nil : agent)
                    : .symbol(agent == .custom ? "checkmark.circle.fill" : agent.symbol, agent == .custom ? Palette.green : agent.tint)
                show(Banner(title: e.title, body: body, style: .success, icon: icon, sticky: e.sticky ?? false))
            }
        case "error", "failed", "failure":
            if let id = e.id, activity(id) != nil {
                agentFinished(id: id, agent: activity(id)?.agent ?? agent, title: e.title, summary: body, failed: true)
            } else {
                show(Banner(title: e.title, body: body, style: .failure,
                            icon: config.buddy ? .buddy(.sad, nil) : .symbol("xmark.octagon.fill", Palette.red),
                            sticky: e.sticky ?? false))
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
        loadArtwork(for: np)
        recompute()
    }

    /// Artwork bytes from the player (Apple Music) or downloaded from its URL (Spotify).
    func setArtwork(_ data: Data, forTrack key: String) {
        guard key == nowPlaying?.trackKey, let image = NSImage(data: data) else { return }
        artwork = image
        accent = ArtworkTint.color(from: image)
    }

    private func loadArtwork(for np: NowPlaying?) {
        guard let np else {
            artworkKey = nil
            artwork = nil
            accent = nil
            return
        }
        guard np.trackKey != artworkKey else { return }
        artworkKey = np.trackKey
        artwork = nil
        accent = nil
        guard let url = np.artworkURL else { return }
        let key = np.trackKey
        Task { [weak self] in
            guard let result = try? await URLSession.shared.data(from: url) else { return }
            self?.setArtwork(result.0, forTrack: key)
        }
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

    // MARK: - Volume / brightness HUD

    func showHUD(_ kind: HUDState.Kind, level: Double, muted: Bool = false) {
        guard config.hud.lowercased() != "off", !expanded else { return }
        hud = HUDState(kind: kind, level: min(max(level, 0), 1), muted: muted)
        hudTimer?.invalidate()
        hudTimer = Timer.scheduledTimer(withTimeInterval: config.hudSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hud = nil
                self?.recompute()
            }
        }
        recompute()
    }

    // MARK: - Calendar & due dates

    func setSchedule(_ updated: Schedule) {
        guard updated != schedule else { return }
        schedule = updated
        recompute()
    }

    /// Upcoming due items within the lookahead window (overdue ones from the last 3 days included).
    var dueSoon: [DueItem] {
        let horizon = Date().addingTimeInterval(TimeInterval(config.dueLookaheadDays) * 86_400)
        return schedule.due.filter { $0.due <= horizon }
    }

    /// Runs every 20 s: refreshes the countdown and fires heads-up banners for thresholds crossed since the last tick.
    private func clockTick() {
        let now = Date()
        let since = lastAlertCheck
        lastAlertCheck = now
        guard config.calendar else { return }

        if config.eventStartAlert {
            for event in schedule.events where event.start > since && event.start <= now && event.end > now {
                let until = event.end.formatted(date: .omitted, time: .shortened)
                var body = "Until \(until)"
                if let location = event.location { body += ", \(location)" }
                show(Banner(
                    title: "Now: \(event.title)",
                    body: body,
                    style: .info,
                    icon: .symbol("calendar", event.color),
                    openURL: event.joinURL,
                    duration: 8
                ))
            }
        }

        if config.meetingAlertMinutes > 0 {
            let lead = TimeInterval(config.meetingAlertMinutes * 60)
            for event in schedule.events {
                let alertAt = event.start.addingTimeInterval(-lead)
                guard alertAt > since, alertAt <= now, event.start > now else { continue }
                let minutes = max(1, Int((event.start.timeIntervalSince(now) / 60).rounded()))
                var body = event.start.formatted(date: .omitted, time: .shortened)
                if let location = event.location { body += " · \(location)" }
                if event.joinURL != nil { body += " · click to join" }
                show(Banner(
                    title: "\(event.title) in \(minutes) min",
                    body: body,
                    style: .attention,
                    icon: .symbol("calendar", event.color),
                    openURL: event.joinURL,
                    duration: 12
                ))
            }
        }

        for item in schedule.due {
            for hours in config.dueAlertHours.sorted(by: >) {
                let alertAt = item.due.addingTimeInterval(-hours * 3600)
                guard alertAt > since, alertAt <= now, item.due > now else { continue }
                show(Banner(
                    title: "Due \(Self.relative(item.due, from: now)): \(item.title)",
                    body: "\(item.source) · \(item.due.formatted(date: .abbreviated, time: .shortened))",
                    style: hours <= 1 ? .attention : .info,
                    icon: .symbol("checklist", item.color),
                    sticky: hours <= 1,
                    duration: 10
                ))
            }
        }
        recompute()
    }

    /// "in 12 min", "in 3h", "tomorrow", "Fri", "2h ago"…
    nonisolated static func relative(_ date: Date, from now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        let minutes = Int((abs(seconds) / 60).rounded())
        if seconds < 0 {
            if minutes < 60 { return "\(max(minutes, 1))m ago" }
            if minutes < 24 * 60 { return "\(minutes / 60)h ago" }
            return "\(minutes / (24 * 60))d overdue"
        }
        if minutes < 1 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        if minutes < 12 * 60 {
            let h = minutes / 60, m = minutes % 60
            return m == 0 ? "in \(h)h" : "in \(h)h \(m)m"
        }
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "today \(date.formatted(date: .omitted, time: .shortened))" }
        if calendar.isDateInTomorrow(date) { return "tomorrow \(date.formatted(date: .omitted, time: .shortened))" }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    // MARK: - Claude Code approvals

    /// "smart" mode: use the notch only when you're at the Mac but not looking at Claude's terminal.
    func shouldRouteApproval(activityID: String) -> Bool {
        switch config.approvals.lowercased() {
        case "off": return false
        case "always": return true
        default:
            if SystemState.screenLocked { return false }
            if SystemState.idleSeconds > config.approvalIdleMinutes * 60 { return false }
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
            if let owner = activity(activityID)?.ownerApp { return front != owner }
            guard let front else { return true }
            return !Self.terminalApps.contains(front)
        }
    }

    func requestApproval(_ request: ApprovalRequest, reply: @escaping @MainActor (ApprovalDecision) -> Void) {
        approvals.append(request)
        approvalReplies[request.id] = reply
        // Reflect it on the session's live activity without a separate banner.
        if var a = activity(request.sessionID) {
            a.state = .attention
            a.detail = "Wants to \(request.action)"
            a.updatedAt = Date()
            put(a)
        }
        lastAgentSignal = Date()
        if config.sounds, let sound = NSSound(named: NSSound.Name(config.attentionSound)) {
            sound.stop()
            sound.play()
        }
        let id = request.id
        _ = Timer.scheduledTimer(withTimeInterval: max(request.expiresAt.timeIntervalSinceNow, 1), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.resolveApproval(id, .ask) }
        }
        recompute()
    }

    func resolveApproval(_ id: UUID, _ decision: ApprovalDecision) {
        guard let index = approvals.firstIndex(where: { $0.id == id }) else { return }
        let request = approvals.remove(at: index)
        approvalReplies.removeValue(forKey: id)?(decision)
        switch decision {
        case .allow, .allowAlways:
            agentUpdate(id: request.sessionID, agent: .claude, title: request.project, detail: "Approved: \(request.action)")
        case .deny:
            agentUpdate(id: request.sessionID, agent: .claude, title: request.project, detail: "Denied: \(request.action)")
        case .ask:
            break // the terminal prompt takes over; Claude's Notification hook will flag it
        }
        recompute()
    }

    /// Answer in the terminal instead: hand the prompt back and jump to Claude's window.
    func answerInTerminal(_ id: UUID) {
        let sessionID = approvals.first(where: { $0.id == id })?.sessionID
        resolveApproval(id, .ask)
        if let sessionID, let a = activity(sessionID) { open(a) }
    }

    /// The hook gave up (Claude Code timed out or was interrupted).
    func cancelApproval(_ id: UUID) {
        approvals.removeAll { $0.id == id }
        approvalReplies.removeValue(forKey: id)
        recompute()
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

    func addToShelf(_ urls: [URL], atFront: Bool = false) {
        for url in urls where !shelf.contains(url) {
            if atFront { shelf.insert(url, at: 0) } else { shelf.append(url) }
        }
        if shelf.count > 24 {
            if atFront { shelf.removeLast(shelf.count - 24) } else { shelf.removeFirst(shelf.count - 24) }
        }
        saveShelf()
    }

    /// New screenshots go to the front of the shelf, with a small thumbnail banner.
    func addScreenshots(_ urls: [URL]) {
        guard config.screenshotsToShelf, !urls.isEmpty else { return }
        addToShelf(urls, atFront: true)
        guard let newest = urls.last else { return }
        show(Banner(
            title: urls.count == 1 ? "Screenshot on the shelf" : "\(urls.count) screenshots on the shelf",
            body: "Hover the notch and drag it anywhere.",
            style: .info,
            icon: .file(newest),
            duration: 2.5,
            showsShelf: true
        ))
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
