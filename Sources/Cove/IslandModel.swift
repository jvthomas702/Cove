import AppKit
import SwiftUI
import Combine

/// All island state lives here. Everything runs on the main actor.
@MainActor
final class IslandModel: ObservableObject {
    enum Presentation: Equatable { case idle, compact, banner, expanded, approval }
    enum Tab: String, CaseIterable { case home, ai, schedule, sports, shelf }

    /// What the two "wings" beside the notch show in compact mode, in priority order.
    enum CompactItem: Equatable {
        case hud(HUDState)
        case attention(AgentKind)
        case napping              // Nori resting beside the notch when nothing is going on
        case event(CalEvent)      // starting soon
        case ongoing(CalEvent)    // happening now
        case running(count: Int, agent: AgentKind)
        case progress(Activity)
        case finished(count: Int, agent: AgentKind, failed: Bool)
        case focus(end: Date)
        case music(NowPlaying)
        case sports(SportsGame)
        case scoreAndMusic(SportsGame, NowPlaying)   // a live score and what's playing, side by side
        case ai(Activity, count: Int)
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
    @Published var availableIslandWidth: CGFloat = 1200 { didSet { recompute() } }

    // State
    @Published var config: CoveConfig {
        didSet { recompute() }
    }
    /// What Cove can see in Calendar (Settings → Features → Calendar).
    @Published var calendarStatus = CalendarStatus()
    /// Pasted calendar links and whether each one loaded.
    @Published var feedStatuses: [FeedStatus] = []
    /// Opens the settings window (set by AppDelegate) so the island can point at a fix.
    var openSettings: ((SettingsPane) -> Void)?
    var applyConfig: ((CoveConfig) -> Void)?
    let sports: SportsMonitor
    let agentLauncher = AgentLauncher()
    let codexChats = CodexChats()
    @Published var composeNewTask = false
    private let shelfStore: ShelfStore
    private let shelfEditor = ShelfEditorController()
    @Published private(set) var canUndoShelf = false
    private var sportsChanges: AnyCancellable?
    /// When the browser extension last reported in (shown in Settings → Connections).
    @Published private(set) var lastExtensionEvent: Date?
    @Published var selectedAIActivityID: String?
    @Published var aiActivityFilter: AIActivityFilter = .all
    @Published var desktopAIStatus = "Checking ChatGPT app…"
    /// GitHub Actions sign-in and what's being watched (Settings → Connections).
    @Published var ciStatus: GitHubActionsMonitor.Status?
    @Published private(set) var presentation: Presentation = .idle
    @Published private(set) var expanded = false
    @Published private(set) var isPinnedOpen = false
    @Published var tab: Tab = .home { didSet { recompute() } }
    @Published private(set) var activities: [Activity] = []
    @Published private(set) var aiSteps: [String: [AIActivityStep]] = [:]
    @Published private(set) var banner: Banner?
    @Published private(set) var history: [Banner] = []
    @Published private(set) var nowPlaying: NowPlaying?
    /// Album art for the current track and the color pulled from it (tints the music UI).
    @Published private(set) var artwork: NSImage?
    @Published private(set) var accent: Color?
    /// A file drag is hovering over the island.
    @Published private(set) var isDropTargeted = false
    @Published private(set) var battery: BatteryState?
    /// Connected AirPods and other Bluetooth accessories that report a battery; nil until first read.
    @Published private(set) var bluetooth: [BluetoothBattery]?
    @Published private(set) var focusEnd: Date?
    @Published private(set) var focusTotal: TimeInterval = 0
    @Published private(set) var shelf: [URL] = []
    /// Recently copied text, newest first (memory only; see ClipboardMonitor).
    @Published private(set) var clips: [String] = []
    /// Whether Cove can read the folder screenshots are saved to.
    @Published var screenshotAccess: ScreenshotWatcher.AccessState = .unknown
    private var lastScreenshotAt: Date?
    @Published private(set) var schedule = Schedule()
    @Published private(set) var hud: HUDState?
    @Published private(set) var approvals: [ApprovalRequest] = []
    @Published var serverStatus = "Starting…"
    /// What the cloud-session watcher is doing, for Settings.
    @Published var cloudStatus = ""

    /// Set by the app delegate: (command, bundleID) → sends play/pause/next to Music or Spotify.
    var mediaControl: ((String, String) -> Void)?

    private var queue: [Banner] = []
    private var bannerTimer: Timer?
    private var focusTimer: Timer?
    private var pruneTimer: Timer?
    private var hoverWork: DispatchWorkItem?
    private var isHovering = false
    private var menuTrackingDepth = 0
    private var suppressHoverUntilExit = false
    private var artworkKey: String?
    private var lastAgentSignal: Date?
    private var reportedNotificationAccessDenied = false
    private var hudTimer: Timer?
    private var clockTimer: Timer?
    private var lastAlertCheck = Date()
    private var approvalReplies: [UUID: @MainActor (ApprovalDecision) -> Void] = [:]

    private static let terminalApps = [
        "com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal", "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty", "org.alacritty", "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92",
    ]

    init(config: CoveConfig, sports: SportsMonitor? = nil, shelfStore: ShelfStore? = nil) {
        self.shelfStore = shelfStore ?? ShelfStore()
        self.config = config
        self.sports = sports ?? SportsMonitor()
        // Relay changes from the nested monitor after its published values have changed.
        sportsChanges = self.sports.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                self?.objectWillChange.send()
                self?.recompute()
                self?.forgetFinishedWatchedGames()
            }
        }
        self.sports.onAutomaticSelection = { [weak self] game in
            guard let self else { return }
            var next = self.config; next.sportsLeague = game.league; next.sportsGameID = game.id
            self.applyConfig?(next)
        }
        self.sports.onAlert = { [weak self] alert in
            self?.show(Banner(title: alert.title, body: alert.body, style: .info, icon: .symbol("sportscourt.fill", Palette.blue), source: "Sports"))
        }
        if config.homeWidget == .ai {
            tab = .ai
            self.config.homeWidget = .sports
        }
        codexChats.onState = { [weak self] chat, status in
            guard let self else { return }
            let id = "codex:\(chat.id)"
            if status.needsYou {
                self.agentAttention(id: id, agent: .codex, title: chat.title, message: status.phase + ". Open this chat in Codex.")
            } else if status.type == "active" {
                self.agentStarted(id: id, agent: .codex, title: chat.title, detail: "Codex is working", ownerApp: "com.openai.codex")
            } else if self.activity(id)?.isLive == true {
                self.agentFinished(id: id, agent: .codex, title: chat.title, summary: "Turn ended", failed: status.type == "systemError", notify: false)
            }
        }
        codexChats.onDisconnect = { [weak self] in
            guard let self else { return }
            for a in self.activities where a.id.hasPrefix("codex:") && a.state == .attention {
                self.agentUpdate(id: a.id, agent: .codex, title: a.title, detail: "Connection unavailable — check Codex", phase: "Status unavailable")
            }
        }
        loadShelf()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.prune() }
        }
        // Drives the calendar countdown and heads-up alerts.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.clockTick() }
        }
    }

    var showsActivityPane: Bool { !activities.isEmpty || !history.isEmpty }

    // MARK: - Sizes

    func size(for p: Presentation) -> CGSize {
        let n = notchSize
        switch p {
        case .idle: return n
        case .compact: return CGSize(width: n.width + compactWing * 2, height: n.height)
        case .banner: return CGSize(width: max(n.width + 200, 390), height: n.height + 60)
        case .expanded:
            // Narrow and short, like the iPhone island opened: just wide enough for the tabs and buttons.
            let width = min(max(n.width + 440, 620), availableIslandWidth)
            if tab == .home { return CGSize(width: width, height: n.height + 150) }
            if tab == .ai { return CGSize(width: width, height: n.height + 330) }
            if tab == .sports { return CGSize(width: width, height: n.height + 280) }
            if tab == .shelf { return CGSize(width: width, height: n.height + (shelf.count <= 4 ? 150 : 220)) }
            return CGSize(width: width, height: n.height + 220)
        case .approval:
            // Grows with the preview (a one-line command vs. an 8-line diff).
            let lines = CGFloat(max(approvals.first?.preview.lines.count ?? 1, 1))
            return CGSize(width: max(n.width + 320, 500), height: n.height + min(124 + lines * 16, 250))
        }
    }

    func chooseIslandTheme(_ theme: IslandTheme) {
        var next = config
        next.islandTheme = theme
        applyConfig?(next)
    }

    /// Width of each wing in compact mode. Wider for things that need words (a class name, a level bar).
    var compactWing: CGFloat {
        switch compactItem {
        case .event?, .ongoing?: return 104
        case .sports?: return 104
        case .scoreAndMusic?: return 116
        case .ai?: return 92
        case .hud?: return 64
        case .napping? where nextEventToday != nil:
            return 60   // napping Nori plus the next class time
        case .napping?, .attention?, .running?, .progress?, .finished?:
            return config.buddy ? 46 : Self.wing   // room for a Nori you can actually see
        default: return Self.wing
        }
    }

    /// Nori's size beside the notch: as tall as the notch allows.
    var compactBuddySize: CGFloat { min(max(notchSize.height - 3, 24), 34) }

    /// Today's next class or meeting within 12 hours, shown next to napping Nori.
    var nextEventToday: CalEvent? {
        guard config.calendar, let next = schedule.upcomingEvent(),
              next.start.timeIntervalSinceNow < 12 * 3600 else { return nil }
        return next
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
        let workingAI = aiActivities.filter(\.isLive)
        if config.aiWorkInNotch, let work = workingAI.first { return .ai(work, count: workingAI.count) }
        if config.homeWidget == .ai, let work = aiActivities.first { return .ai(work, count: workingAI.count) }
        if config.sportsEnabled, config.homeWidget == .sports, let game = sports.selectedGame, !game.isFinal {
            if let np = nowPlaying, np.isPlaying { return .scoreAndMusic(game, np) }
            return .sports(game)
        }
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
        if config.buddy && config.buddyAlwaysVisible { return .napping }
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
            DispatchQueue.main.asyncAfter(deadline: .now() + max(config.hoverDelay, 0.20), execute: work)
        } else if changed {
            suppressHoverUntilExit = false
            scheduleCollapse(after: 0.65)
        }
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverWork = nil
                guard !self.isHovering, !self.isDropTargeted, self.menuTrackingDepth == 0, !self.isPinnedOpen else { return }
                self.setExpanded(false)
            }
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Native popup menus extend outside the island. Keep the parent alive until tracking ends.
    func setMenuTracking(_ tracking: Bool) {
        menuTrackingDepth = tracking ? menuTrackingDepth + 1 : max(0, menuTrackingDepth - 1)
        hoverWork?.cancel()
        hoverWork = nil
        if menuTrackingDepth == 0, !isHovering { scheduleCollapse(after: 0.65) }
    }

    func setExpanded(_ value: Bool) {
        if !value { isPinnedOpen = false }
        guard value != expanded else { return }
        expanded = value
        // Closed on purpose (a click) while the pointer is still over it: don't re-open until it leaves.
        if !value && isHovering { suppressHoverUntilExit = true }
        if value {
            // Just took a screenshot? Open straight to the shelf so it's ready to drag.
            if config.screenshotBanners, let shot = lastScreenshotAt,
               Date().timeIntervalSince(shot) < 15, !shelf.isEmpty { tab = .shelf }
            // Opening the island shows everything, so pending banners are folded into history.
            bannerTimer?.invalidate()
            bannerTimer = nil
            banner = nil
            queue.removeAll()
        } else {
            markAllSeen()
            if tab == .shelf && shelf.isEmpty { tab = .home }
        }
        recompute()
    }

    func toggleExpanded() { setExpanded(!expanded) }

    func openByClick() {
        isPinnedOpen = true
        hoverWork?.cancel(); hoverWork = nil
        setExpanded(true)
    }

    func navigate(to destination: Tab) {
        openByClick()
        tab = destination
    }

    func openAIConnections() {
        openByClick()
        openSettings?(.connections)
    }

    func togglePinnedOpen() {
        isPinnedOpen.toggle()
        if isPinnedOpen { hoverWork?.cancel(); hoverWork = nil; setExpanded(true) }
        else if !isHovering { scheduleCollapse(after: 0.65) }
    }

    func toggleFavorite(_ teamID: String, league: SportsLeague) {
        var next = config
        let key = "\(league.rawValue):\(teamID)"
        if next.sportsFavoriteTeams.contains(key) { next.sportsFavoriteTeams.removeAll { $0 == key } }
        else { next.sportsFavoriteTeams.append(key) }
        applyConfig?(next)
    }

    func toggleWatchedGame(_ game: SportsGame) {
        var next = config
        if next.sportsWatchedGames.contains(game.key) { next.sportsWatchedGames.removeAll { $0 == game.key } }
        else { next.sportsWatchedGames.append(game.key) }
        applyConfig?(next)
    }

    /// Followed games that haven't ended; a game drops out of the list once it's final.
    var followedSportsGames: [SportsGame] {
        var games = sports.allGames.filter { $0.isFollowed(in: config) && !$0.isFinal }
        if let game = sports.selectedGame, !game.isFinal, !games.contains(where: { $0.key == game.key }) { games.insert(game, at: 0) }
        return games.sorted { if $0.isLive != $1.isLive { return $0.isLive }; return ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }

    /// Games followed one at a time are only worth following until they end.
    func forgetFinishedWatchedGames() {
        let ended = SportsFollowRules.finishedWatchedGames(sports.allGames, config: config)
        guard !ended.isEmpty else { return }
        var next = config
        next.sportsWatchedGames.removeAll { ended.contains($0) }
        applyConfig?(next)
    }

    func chooseSportsLeague(_ league: SportsLeague) {
        guard league != config.sportsLeague else { return }
        var next = config
        next.sportsLeague = league
        next.sportsGameID = nil
        applyConfig?(next)
    }

    func chooseSportsGame(_ game: SportsGame) {
        var next = config
        next.sportsLeague = game.league
        next.sportsGameID = game.id
        next.homeWidget = .sports
        next.sportsEnabled = true
        applyConfig?(next)
    }

    var visibleSportsGames: [SportsGame] {
        sports.games.filter { config.sportsLeague != .collegeFootball || !config.sportsRankedOnly || $0.isRanked || $0.isFavorite(in: config) }
    }

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
        if b.logged {
            history.insert(b, at: 0)
            if history.count > 40 { history.removeLast(history.count - 40) }
        }
        // A newer shelf banner replaces the one on screen instead of queueing behind it.
        if b.showsShelf, let current = banner, current.showsShelf, !expanded {
            queue.removeAll { $0.showsShelf }
            present(b)
            return
        }
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
        recordAIStep(a)
        if let i = activities.firstIndex(where: { $0.id == a.id }) {
            activities[i] = a
        } else {
            activities.insert(a, at: 0)
        }
        recompute()
    }

    private func recordAIStep(_ a: Activity) {
        guard a.agent.isAI else { return }
        var steps = aiSteps[a.id] ?? []
        if let previous = activity(a.id), previous.startedAt != a.startedAt { steps = [] }
        let phase = a.phase ?? (a.isLive ? "Working" : "Finished")
        let detail = String(a.detail.prefix(2000))
        if let last = steps.last, last.phase == phase, last.state == a.state {
            steps[steps.count - 1].detail = detail
            steps[steps.count - 1].date = a.updatedAt
        } else {
            steps.append(AIActivityStep(phase: phase, detail: detail, state: a.state, date: a.updatedAt))
        }
        aiSteps[a.id] = Array(steps.suffix(24))
        if aiSteps.count > 24 {
            let oldest = aiSteps.filter { $0.key != a.id }.min { ($0.value.last?.date ?? .distantPast) < ($1.value.last?.date ?? .distantPast) }
            if let oldest { aiSteps.removeValue(forKey: oldest.key) }
        }
    }

    func agentStarted(id: String, agent: AgentKind, title: String, detail: String, ownerApp: String?) {
        let now = Date()
        dropBanners(forActivity: id)
        var a = activity(id) ?? Activity(id: id, agent: agent, title: title, detail: detail, state: .running, startedAt: now, updatedAt: now)
        if !a.isLive { a.startedAt = now }
        a.title = title
        a.detail = detail
        a.state = .running
        a.phase = "Working"
        a.progress = nil
        a.finishedAt = nil
        a.seen = true
        a.updatedAt = now
        if let ownerApp, ownerApp != Bundle.main.bundleIdentifier { a.ownerApp = ownerApp }
        put(a)
    }

    func agentUpdate(id: String, agent: AgentKind, title: String, detail: String, progress: Double? = nil, phase: String? = nil) {
        let now = Date()
        var a = activity(id) ?? Activity(id: id, agent: agent, title: title, detail: detail, state: .running, startedAt: now, updatedAt: now)
        if a.state == .attention { dropBanners(forActivity: id); a.phase = "Working" }
        if !a.isLive { a.startedAt = now; a.finishedAt = nil; a.seen = true; a.phase = "Working" }
        a.state = .running
        a.title = title
        a.detail = detail
        if let phase { a.phase = phase.oneLine(max: 60) }
        if let progress { a.progress = min(max(progress, 0), 1) }
        a.updatedAt = now
        put(a)
    }

    func agentAttention(id: String, agent: AgentKind, title: String, message: String) {
        let now = Date()
        let alreadyWaiting = activity(id)?.state == .attention
        var a = activity(id) ?? Activity(id: id, agent: agent, title: title, detail: message, state: .attention, startedAt: now, updatedAt: now)
        a.finishedAt = nil
        a.seen = false
        a.state = .attention
        a.phase = "Needs you"
        a.title = title
        a.detail = message
        a.updatedAt = now
        put(a)
        lastAgentSignal = now
        guard !alreadyWaiting else { return }
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

    func agentFinished(id: String, agent: AgentKind, title: String, summary: String?, failed: Bool = false, notify: Bool = true) {
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
        a.phase = failed ? "Failed" : "Finished"
        a.seen = expanded
        a.detail = summaryText ?? took.map { "Finished in \(formatDuration($0))" } ?? "Finished"
        put(a)
        lastAgentSignal = now
        guard notify else { return }
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

    func updateFinishedSummary(id: String, summary: String) {
        guard let index = activities.firstIndex(where: { $0.id == id }), activities[index].state == .done else { return }
        activities[index].detail = summary
    }

    func setUsage(id: String, _ usage: TokenUsage) {
        guard var a = activity(id), a.tokens != usage else { return }
        a.tokens = usage
        put(a)
    }

    func removeActivity(_ id: String) {
        activities.removeAll { $0.id == id }
        aiSteps.removeValue(forKey: id)
        dropBanners(forActivity: id)
        recompute()
    }

    func open(_ a: Activity) {
        markSeen(a.id)
        if let url = a.openURL {
            if let owner = a.ownerApp, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: owner) {
                NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
            } else { NSWorkspace.shared.open(url) }
        } else if let owner = a.ownerApp, activateApp(owner) {
            // jumped back to the terminal / editor that started it
        } else if let terminal = Self.terminalApps.first(where: { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }) {
            activateApp(terminal)
        }
        setExpanded(false)
    }

    /// The browser the extension is most likely running in (the frontmost one, else the first running one).
    static func runningBrowser() -> String? {
        let browsers = ["com.google.Chrome", "company.thebrowser.Browser", "com.brave.Browser",
                        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "com.operasoftware.Opera", "com.google.Chrome.canary"]
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, browsers.contains(front) { return front }
        return browsers.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
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
        let retained = Set(activities.map(\.id))
        aiSteps = aiSteps.filter { retained.contains($0.key) }
        recompute()
    }

    // MARK: - GitHub Actions

    /// A CI run started or changed state (see GitHubActionsMonitor).
    func ciRun(_ run: CIRun) {
        let id = "ci:\(run.id)"
        let title = "\(run.repoName) · \(run.workflow)"
        let where_ = [run.branch, run.commit].filter { !$0.isEmpty }.joined(separator: " · ")
        switch run.state {
        case .running:
            if activity(id) == nil { agentStarted(id: id, agent: .ci, title: title, detail: where_, ownerApp: nil) }
            agentUpdate(id: id, agent: .ci, title: title, detail: where_)
        case .passed:
            agentFinished(id: id, agent: .ci, title: title, summary: nil)
        case .failed:
            agentFinished(id: id, agent: .ci, title: title, summary: run.branch.isEmpty ? nil : "Failed on \(run.branch)", failed: true)
        case .cancelled:
            removeActivity(id)
            return
        }
        if var a = activity(id), a.openURL != run.url {
            a.openURL = run.url
            put(a)
        }
    }

    // MARK: - Claude in the cloud

    /// A pull request from a Claude cloud session changed phase. Shown as a Claude activity that opens
    /// the session (or project thread) when clicked; `announce` adds a banner.
    func cloudUpdate(_ pr: CloudPR, phase: CloudPR.Phase, announce: Bool) {
        let id = pr.id
        guard phase != .closed else { removeActivity(id); return }
        let now = Date()
        let title = "\(pr.repoName) #\(pr.number)"
        var a = activity(id) ?? Activity(id: id, agent: .claude, title: title, detail: "", state: .running,
                                         startedAt: pr.createdAt, updatedAt: now)
        a.title = title
        a.detail = "\(phase.label) · \(pr.title)"
        a.phase = phase.label
        a.openURL = pr.link
        a.updatedAt = now
        a.progress = nil
        switch phase {
        case .draft, .ciRunning:
            a.state = .running
            a.finishedAt = nil
        case .ciFailed:
            a.state = .failed
            a.finishedAt = now
        case .draftPassed, .ready, .merged, .closed:
            a.state = .done
            a.finishedAt = now
        }
        a.seen = a.isLive || !announce || expanded
        put(a)
        guard announce else { return }
        lastAgentSignal = now

        let heading: String
        let style: BannerStyle
        let mood: BuddyMood
        switch phase {
        case .draft, .ciRunning:
            // Only a brand-new PR is announced while work is still going; new pushes update quietly.
            heading = "Claude opened a PR"; style = .info; mood = .working
        case .ciFailed: heading = "CI failed"; style = .failure; mood = .sad
        case .draftPassed: heading = "CI passed"; style = .success; mood = .happy
        case .ready: heading = "Ready for review"; style = .success; mood = .happy
        case .merged, .closed: heading = "Merged"; style = .success; mood = .happy
        }
        show(Banner(
            title: "\(heading) · \(title)",
            body: pr.title,
            style: style,
            icon: config.buddy ? .buddy(mood, .claude) : .symbol(AgentKind.claude.symbol, AgentKind.claude.tint),
            activityID: id,
            source: "Claude in the cloud"
        ))
    }

    // MARK: - Generic events (POST /event, cove-notify, cove-run)

    func ingest(_ e: CoveEvent) {
        let kind = (e.kind ?? "info").lowercased()
        // Desktop runtime state supersedes early hooks and duplicate completion notifiers.
        if e.source?.lowercased() == "codex", let id = e.id, id.hasPrefix("codex:"),
           codexChats.ignoresHook(String(id.dropFirst(6)), kind: kind) { return }
        let sourceName = (e.source ?? "custom").lowercased()
        if ["chatgpt", "gemini", "claude-web"].contains(sourceName), e.id?.hasPrefix("desktop:") != true { lastExtensionEvent = Date() }
        let agent = AgentKind(rawValue: sourceName == "claude-web" ? "claude" : sourceName) ?? .custom
        let body = e.body ?? ""
        switch kind {
        case "running", "progress", "start", "started":
            let id = e.id ?? "event:\(e.title)"
            if activity(id) == nil {
                let owner = e.app ?? ((agent.isWeb || e.source?.lowercased() == "claude-web") ? Self.runningBrowser() : nil)
                agentStarted(id: id, agent: agent, title: e.title, detail: body, ownerApp: owner)
            }
            agentUpdate(id: id, agent: agent, title: e.title, detail: body, progress: e.progress, phase: e.phase)
            updateAIContext(id: id, phase: e.phase, url: e.url)
        case "done", "success", "finished", "complete":
            if let id = e.id, activity(id) != nil || agent.isAI {
                if activity(id) == nil {
                    agentStarted(id: id, agent: agent, title: e.title, detail: body, ownerApp: e.app ?? Self.runningBrowser())
                    updateAIContext(id: id, phase: e.phase, url: e.url)
                }
                agentFinished(id: id, agent: activity(id)?.agent ?? agent, title: e.title, summary: body, notify: !(e.silent ?? false))
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

    var aiActivities: [Activity] {
        activities.filter { $0.agent.isAI }.sorted {
            if $0.isLive != $1.isLive { return $0.isLive }
            return $0.updatedAt > $1.updatedAt
        }
    }

    var filteredAIActivities: [Activity] { aiActivities.filter(aiActivityFilter.includes) }

    var selectedAIActivity: Activity? {
        let visible = filteredAIActivities
        return visible.first { $0.id == selectedAIActivityID } ?? visible.first
    }

    func selectAIActivity(_ activity: Activity) {
        if !aiActivityFilter.includes(activity) { aiActivityFilter = .all }
        selectedAIActivityID = activity.id
    }

    var aiStatusState: ActivityState? {
        let work = aiActivities
        for state in [ActivityState.attention, .running, .failed, .done] {
            if work.contains(where: { $0.state == state }) { return state }
        }
        return nil
    }

    var aiStatusTitle: String {
        let waiting = aiActivities.filter { $0.state == .attention }.count
        if waiting > 0 { return "\(waiting) \(waiting == 1 ? "needs" : "need") you" }
        let running = aiActivities.filter { $0.state == .running }.count
        if running > 0 { return "\(running) working" }
        if aiActivities.contains(where: { $0.state == .failed }) { return "Task failed" }
        return aiActivities.isEmpty ? "Ready when you are" : "All caught up"
    }

    var desktopAITrackingStatus: String {
        config.desktopAIActivity ? desktopAIStatus : "Tracking is off"
    }

    private func updateAIContext(id: String, phase: String?, url: String?) {
        guard let index = activities.firstIndex(where: { $0.id == id }) else { return }
        if let phase { activities[index].phase = phase.oneLine(max: 60) }
        if let url = Self.chatURL(url) { activities[index].openURL = url }
        recordAIStep(activities[index])
        recompute()
    }

    static func chatURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.user == nil, url.password == nil,
              ["chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        return url
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
        guard !reportedNotificationAccessDenied else { return }
        reportedNotificationAccessDenied = true
        show(Banner(
            title: "Notification mirroring is optional",
            body: "Allow Full Disk Access in Settings if you want macOS notifications in Cove.",
            style: .info,
            icon: .symbol("lock.shield.fill", Palette.blue),
            sticky: false,
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

    /// New Bluetooth readings: a banner when headphones connect, and when anything runs low.
    func setBluetooth(_ devices: [BluetoothBattery]) {
        let old = bluetooth
        bluetooth = devices
        guard let old else { return } // first reading: just learn what's connected
        for device in devices {
            let icon = BannerIcon.symbol(device.symbol, Theme.ink)
            guard let before = old.first(where: { $0.name == device.name }) else {
                show(Banner(title: "\(device.name) connected", body: device.summary, style: .info, icon: icon, duration: 3))
                continue
            }
            guard let now = device.lowest, let was = before.lowest else { continue }
            for threshold in [10, 20] where now <= threshold && was > threshold {
                show(Banner(title: "\(device.name) battery low", body: device.summary, style: .attention,
                            icon: .symbol(device.symbol, Palette.red), sticky: threshold == 10))
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

    /// Why the Schedule tab might be empty, if something needs setting up. Nil when everything is connected.
    var scheduleSetup: ScheduleSetup? {
        for feed in feedStatuses {
            if case .failed(let reason) = feed.state {
                return ScheduleSetup(title: "\(feed.name) link didn't load", detail: reason, action: "Fix", pane: .features)
            }
        }
        if !schedule.events.isEmpty || !schedule.due.isEmpty { return nil }
        if feedStatuses.contains(where: { $0.state == .loading }) {
            return ScheduleSetup(title: "Loading your calendars…", detail: nil, action: nil, pane: nil)
        }
        if !feedStatuses.isEmpty { return nil }
        // Only the Mac's built-in calendars means D2L and Google aren't connected yet.
        let builtIn = ["home", "work", "calendar", "scheduled reminders", "us holidays", "holidays", "birthdays", "siri suggestions"]
        let onlyBuiltIn = calendarStatus.calendars.allSatisfy { name in
            builtIn.contains(name.lowercased()) || name.lowercased().hasPrefix("holidays in")
        }
        if config.calendar && calendarStatus.access == .granted && !onlyBuiltIn { return nil }
        return ScheduleSetup(title: "Connect D2L and Google Calendar",
                             detail: "Paste your calendar links in Settings and your classes and due dates show up here.",
                             action: "Add links", pane: .features)
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
        // A reconnect may deliver the permission before a start hook.
        let now = Date()
        var a = activity(request.sessionID) ?? Activity(id: request.sessionID, agent: .claude, title: request.project, detail: "", state: .running, startedAt: now, updatedAt: now)
        dropBanners(forActivity: request.sessionID)
        a.state = .attention
        a.phase = "Waiting for approval"
        a.finishedAt = nil
        a.detail = "Wants to \(request.action)"
        a.updatedAt = now
        put(a)
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

    /// A global shortcut (see HotKeys). Approval keys do nothing unless a prompt is waiting.
    func handleShortcut(_ action: HotKeys.Action) {
        guard let request = approvals.first else {
            if action == .toggle { setExpanded(!expanded) }
            return
        }
        switch action {
        case .toggle: setExpanded(!expanded)
        case .allow: resolveApproval(request.id, .allow)
        case .deny: resolveApproval(request.id, .deny)
        case .alwaysAllow where request.canAlwaysAllow: resolveApproval(request.id, .allowAlways)
        case .alwaysAllow: break
        case .terminal: answerInTerminal(request.id)
        }
    }

    /// Answer in the terminal instead: hand the prompt back and jump to Claude's window.
    func answerInTerminal(_ id: UUID) {
        let sessionID = approvals.first(where: { $0.id == id })?.sessionID
        resolveApproval(id, .ask)
        if let sessionID, let a = activity(sessionID) { open(a) }
    }

    /// The hook gave up (Claude Code timed out or was interrupted).
    func cancelApproval(_ id: UUID) {
        let request = approvals.first { $0.id == id }
        approvals.removeAll { $0.id == id }
        approvalReplies.removeValue(forKey: id)
        if let request, let a = activity(request.sessionID), a.state == .attention,
           !approvals.contains(where: { $0.sessionID == request.sessionID }) {
            agentUpdate(id: a.id, agent: a.agent, title: a.title, detail: "Approval closed; waiting for agent status", phase: "Status unavailable")
        }
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
        shelfStore.add(urls, atFront: atFront)
        shelf = shelfStore.urls
        recompute()
    }

    /// New screenshots go to the front of the shelf, with a small thumbnail banner.
    func addScreenshots(_ urls: [URL]) {
        guard config.screenshotsToShelf, !urls.isEmpty else { return }
        // Repeated watcher callbacks must not produce another banner for a capture already on the shelf.
        var seen = Set<URL>()
        let fresh = urls.filter { seen.insert($0).inserted && !shelfStore.contains($0) }
        guard !fresh.isEmpty else { return }
        let placed = config.screenshotsMoveOffDesktop ? fresh.map(Self.moveOffDesktop) : fresh
        addToShelf(placed, atFront: true)
        guard config.screenshotBanners else { return }
        lastScreenshotAt = Date()
        guard let newest = placed.last else { return }
        Haptics.tap()
        show(Banner(
            title: placed.count == 1 ? "Screenshot saved to the shelf" : "\(placed.count) screenshots saved to the shelf",
            body: "Drag the thumbnail anywhere, or hover the notch",
            style: .info,
            icon: .file(newest),
            duration: 4,
            showsShelf: true,
            logged: false
        ))
    }

    func setScreenshotAccess(_ state: ScreenshotWatcher.AccessState, folder: URL) {
        screenshotAccess = state
        // Permission status belongs in Settings → Permissions, without a persistent popup on wake.
    }

    /// ~/Pictures/Screenshots, created on demand.
    nonisolated static var screenshotArchive: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Screenshots", isDirectory: true)
    }

    nonisolated static func moveOffDesktop(_ url: URL) -> URL {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: screenshotArchive, withIntermediateDirectories: true)
            var target = screenshotArchive.appendingPathComponent(url.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: target.path) {
                let base = url.deletingPathExtension().lastPathComponent
                target = screenshotArchive.appendingPathComponent("\(base) \(n).\(url.pathExtension)")
                n += 1
            }
            try fm.moveItem(at: url, to: target)
            return target
        } catch {
            return url
        }
    }

    /// Copies a shelf file so it pastes as a file in Finder and as an image in chat apps.
    func copyToPasteboard(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var objects: [NSPasteboardWriting] = [url as NSURL]
        if let image = NSImage(contentsOf: url) { objects.append(image) }
        pasteboard.writeObjects(objects)
        Haptics.tap()
    }

    func removeFromShelf(_ url: URL) {
        shelfStore.remove(url)
        canUndoShelf = shelfStore.canUndo
        shelf = shelfStore.urls
        recompute()
    }

    func clearShelf() {
        shelfStore.clear()
        canUndoShelf = shelfStore.canUndo
        shelf = []
        recompute()
    }

    func undoShelfRemoval() {
        shelfStore.undo(); shelf = shelfStore.urls; canUndoShelf = shelfStore.canUndo; recompute()
    }

    func previewShelfItem(_ url: URL) { shelfEditor.show(url: url, model: self) }

    func renameShelfItem(_ url: URL, baseName: String) throws -> URL {
        let renamed = try shelfStore.rename(url, baseName: baseName)
        shelf = shelfStore.urls; return renamed
    }

    func saveAnnotatedShelfImage(_ data: Data, name: String) throws -> URL {
        let url = try shelfStore.saveEditedImage(data, name: name)
        shelf = shelfStore.urls; recompute(); return url
    }

    // MARK: - Clipboard history

    func addClip(_ text: String) {
        clips.removeAll { $0 == text }
        clips.insert(text, at: 0)
        if clips.count > 12 { clips.removeLast(clips.count - 12) }
    }

    func copyClip(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        Haptics.tap()
    }

    func removeClip(_ text: String) { clips.removeAll { $0 == text } }

    func clearClips() {
        clips.removeAll()
    }

    private func loadShelf() {
        canUndoShelf = shelfStore.canUndo
        shelf = shelfStore.urls
    }
}
