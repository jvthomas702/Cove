import AppKit
import SwiftUI

/// Hover the notch to open this: up next, media, focus, agent activity, schedule, and the file shelf.
struct ExpandedView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Group {
                switch model.tab {
                case .home: HomePane(model: model)
                case .schedule: SchedulePane(model: model)
                case .sports: SportsPane(model: model)
                case .shelf: ShelfPane(model: model)
                }
            }
            .id(model.tab)
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
            .padding(.horizontal, 14)
            .padding(.top, Theme.Space.s)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(Theme.ink)
        .animation(Theme.snappy, value: model.tab)
    }

    private var header: some View {
        HStack(spacing: 0) {
            TabSwitcher(model: model)
                .frame(maxWidth: .infinity, alignment: .leading)
            Color.clear.frame(width: model.notchSize.width)
            Group {
                if let battery = model.battery { BatteryGlyph(state: battery) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .frame(height: model.notchSize.height)
    }
}

/// Segmented control with a pill that slides to the selected tab.
private struct TabSwitcher: View {
    @ObservedObject var model: IslandModel
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(IslandModel.Tab.allCases, id: \.self) { tab in
                Button {
                    model.tab = tab
                } label: {
                    Image(systemName: symbol(for: tab))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(model.tab == tab ? Theme.ink : Theme.inkTertiary)
                        .frame(width: 30, height: 20)
                        .background {
                            if model.tab == tab {
                                Capsule().fill(Theme.surfaceRaised).matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if tab == .shelf, !model.shelf.isEmpty, model.tab != .shelf {
                                Circle().fill(Palette.blue).frame(width: 5, height: 5).offset(x: -5, y: 3)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PressableStyle())
                .help(label(for: tab))
                .accessibilityLabel(label(for: tab))
                .accessibilityIdentifier("tab.\(tab.rawValue)")
            }
        }
        .padding(2)
        .background(Capsule().fill(Theme.surface))
    }

    private func symbol(for tab: IslandModel.Tab) -> String {
        switch tab {
        case .home: return "house.fill"
        case .schedule: return "calendar"
        case .sports: return "sportscourt.fill"
        case .shelf: return "tray.full.fill"
        }
    }

    private func label(for tab: IslandModel.Tab) -> String {
        switch tab {
        case .home: return "Home"
        case .schedule: return "Schedule"
        case .sports: return "Sports"
        case .shelf: return "Shelf"
        }
    }
}

// MARK: - Home

struct HomePane: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(spacing: Theme.Space.s) {
                HStack {
                    Text("Widget").font(Theme.Font.caption).foregroundStyle(Theme.inkTertiary)
                    Picker("Home widget", selection: Binding(get: { model.config.homeWidget }, set: { widget in
                        var next = model.config
                        next.homeWidget = widget
                        model.applyConfig?(next)
                    })) {
                        ForEach(HomeWidget.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .accessibilityIdentifier("home.widget")
                }
                ScrollView {
                    VStack(spacing: Theme.Space.s) {
                        switch model.config.homeWidget {
                        case .sports: SportsWidget(model: model)
                        case .calendar: UpNextCard(model: model)
                        case .music: MediaCard(model: model)
                        case .focus: FocusCard(model: model)
                        case .ai: AIWorkWidget(model: model)
                        case .auto:
                            if model.aiActivities.contains(where: \.isLive) {
                                AIWorkWidget(model: model)
                            } else if model.config.sportsEnabled, model.sports.selectedGame != nil {
                                SportsWidget(model: model)
                            } else {
                                if model.schedule.nextEvent() != nil || !model.dueSoon.isEmpty { UpNextCard(model: model) }
                                if model.nowPlaying != nil { MediaCard(model: model) }
                                FocusCard(model: model)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollIndicators(.automatic)
            }
            .frame(width: model.showsActivityPane ? 280 : nil)
            .frame(maxWidth: model.showsActivityPane ? 280 : .infinity)

            if model.showsActivityPane {
                ActivityList(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

struct MediaCard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        Group {
            if let np = model.nowPlaying {
                let tint = model.accent ?? np.appTint
                VStack(spacing: Theme.Space.s) {
                    HStack(spacing: 10) {
                        ArtworkView(model: model, size: 44, matchID: "art")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(np.title)
                                .help("\(np.title) — \(np.artist)")
                                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                            Text(np.artist)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 0) {
                            IconButton(systemImage: "backward.fill", size: 10, hit: 22) { model.media("previous track") }
                            IconButton(systemImage: np.isPlaying ? "pause.fill" : "play.fill", size: 15, hit: 26) { model.media("playpause") }
                                .contentTransition(.symbolEffect(.replace))
                            IconButton(systemImage: "forward.fill", size: 10, hit: 22) { model.media("next track") }
                        }
                        .padding(.trailing, -4)
                        .layoutPriority(1)
                    }
                    PlaybackBar(nowPlaying: np, tint: tint)
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.05)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                )
                .card()
                .animation(.easeInOut(duration: 0.6), value: model.accent)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "music.note")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.inkTertiary)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surface))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing playing").font(Theme.Font.headline)
                        Text("Play something in Music or Spotify")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(maxHeight: .infinity)
                .card()
            }
        }
        .frame(height: 92)
    }
}

struct FocusCard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 8) {
            if let end = model.focusEnd {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let remaining = max(0, end.timeIntervalSince(context.date))
                    ProgressRing(progress: remaining / max(model.focusTotal, 1), color: Palette.amber, size: 26, lineWidth: 3)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("Focus")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkSecondary)
                    Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                        .font(.system(size: 17, weight: .semibold, design: .rounded).monospacedDigit())
                }
                Spacer(minLength: 0)
                ChipButton(title: "End", systemImage: "stop.fill", tint: Palette.red) { model.stopFocus() }
            } else {
                Image(systemName: "timer")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.amber)
                Text("Focus").font(Theme.Font.headline).lineLimit(1).fixedSize()
                Spacer(minLength: 2)
                HStack(spacing: 4) {
                    ForEach(model.config.focusMinutes.prefix(3), id: \.self) { minutes in
                        ChipButton(title: "\(minutes)m") { model.startFocus(minutes: minutes) }
                    }
                }
                .layoutPriority(1)
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 48)
        .card()
    }
}

// MARK: - Calendar

struct UpNextCard: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if let current = model.config.calendar ? model.schedule.currentEvent() : nil {
            NowCard(event: current, next: model.schedule.upcomingEvent())
                .contentShape(Rectangle())
                .onTapGesture { model.tab = .schedule }
        } else {
            upNext
        }
    }

    private var upNext: some View {
        let next = model.schedule.nextEvent()
        let dueCount = model.dueSoon.count
        return HStack(spacing: 10) {
            Capsule()
                .fill(next?.color ?? Theme.surfaceRaised)
                .frame(width: 4, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                if let next {
                    Text(next.title)
                        .font(Theme.Font.headline)
                        .lineLimit(1)
                    let place = next.location.map { ", " + $0 } ?? ""
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(IslandModel.relative(next.start, from: context.date).capitalizedFirst + place)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.inkSecondary)
                            .lineLimit(1)
                    }
                } else if let setup = model.scheduleSetup {
                    Text(setup.title).font(Theme.Font.headline).lineLimit(1)
                    Text(setup.action == nil ? "One moment" : "Tap to see how")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkSecondary)
                } else {
                    Text("Nothing else today").font(Theme.Font.headline)
                    Text(dueCount == 0 ? "No deadlines this week" : "\(dueCount) due this week")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkSecondary)
                }
            }
            Spacer(minLength: 0)
            if let url = next?.joinURL {
                ChipButton(title: "Join", systemImage: "video.fill", tint: Palette.green) { NSWorkspace.shared.open(url) }
            } else if next != nil, dueCount > 0 {
                Text("\(dueCount) due")
                    .font(Theme.Font.number)
                    .foregroundStyle(Palette.amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Palette.amber.opacity(0.14)))
            }
        }
        .padding(.horizontal, Theme.Space.m)
        .frame(height: 52)
        .card()
        .contentShape(Rectangle())
        .onTapGesture { model.tab = .schedule }
    }
}

/// The class or meeting happening right now, with how far through it you are.
private struct NowCard: View {
    let event: CalEvent
    let next: CalEvent?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let total = max(event.end.timeIntervalSince(event.start), 1)
            let done = min(max(context.date.timeIntervalSince(event.start) / total, 0), 1)
            let left = max(Int((event.end.timeIntervalSince(context.date) / 60).rounded(.up)), 0)
            HStack(spacing: 10) {
                Capsule().fill(event.color).frame(width: 4, height: 34)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("Now")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Palette.green))
                        Text(event.title)
                            .font(Theme.Font.headline)
                            .lineLimit(1)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule().fill(event.color).frame(width: geo.size.width * done)
                        }
                    }
                    .frame(height: 3)
                    Text(subtitle(minutesLeft: left))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let url = event.joinURL {
                    ChipButton(title: "Join", systemImage: "video.fill", tint: Palette.green) { NSWorkspace.shared.open(url) }
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 52)
            .card(Palette.green.opacity(0.07))
        }
    }

    private func subtitle(minutesLeft: Int) -> String {
        var parts = ["\(minutesLeft) min left"]
        if let location = event.location { parts.append(location) }
        if let next, next.start.timeIntervalSince(event.end) < 3 * 3600 {
            parts.append("then \(next.title)")
        }
        return parts.joined(separator: ", ")
    }
}

struct SchedulePane: View {
    @ObservedObject var model: IslandModel

    private var lookahead: String {
        let days = model.config.dueLookaheadDays
        return days == 7 ? "week" : days == 14 ? "two weeks" : "\(days) days"
    }

    /// " · from D2L and Google Calendar"
    private var sourceSuffix: String {
        var names = model.feedStatuses.filter { $0.state == .ok }.map(\.name)
        if model.config.calendar && model.calendarStatus.access == .granted { names.append("Calendar") }
        guard !names.isEmpty else { return "" }
        let list = names.count <= 2 ? names.joined(separator: " and ") : names.dropLast().joined(separator: ", ") + " and " + names.last!
        return " · from \(list)"
    }

    var body: some View {
        let events = Array(model.schedule.events.filter { $0.end > Date() }.prefix(8))
        let due = Array(model.dueSoon.prefix(10))
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionTitle(title: "Up next", count: events.count)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        if let setup = model.scheduleSetup {
                            SetupNote(setup: setup) { if let pane = setup.pane { model.openSettings?(pane) } }
                        }
                        if events.isEmpty && (model.scheduleSetup == nil || !due.isEmpty) {
                            EmptyNote(symbol: "calendar", text: "Nothing in the next two days\(sourceSuffix)")
                        }
                        ForEach(events) { EventRow(event: $0) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionTitle(title: "Due soon", count: due.count)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        if due.isEmpty {
                            EmptyNote(symbol: "checklist",
                                      text: model.scheduleSetup == nil ? "Nothing due in the next \(lookahead)" : "Due dates from D2L show up here")
                        }
                        ForEach(due) { DueRow(item: $0) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// "Connect D2L and Google Calendar" with a button that opens the right settings page.
private struct SetupNote: View {
    let setup: ScheduleSetup
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: setup.action == nil ? "arrow.triangle.2.circlepath" : "link.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.amber)
                Text(setup.title)
                    .font(Theme.Font.headline)
                    .lineLimit(1)
            }
            if let detail = setup.detail {
                Text(detail)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.inkSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let title = setup.action {
                ChipButton(title: title, systemImage: "gearshape.fill", tint: Palette.amber, action: action)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Palette.amber.opacity(0.09)))
    }
}

private struct EmptyNote: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.inkTertiary)
            Text(text)
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
    }
}

struct EventRow: View {
    let event: CalEvent

    var body: some View {
        let now = Date()
        let live = event.start <= now && event.end > now
        HStack(spacing: 10) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(event.start.formatted(date: .omitted, time: .shortened))
                    .font(Theme.Font.number)
                    .foregroundStyle(live ? Palette.green : Theme.ink)
                Text(event.end.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.inkTertiary)
            }
            .frame(width: 58, alignment: .trailing)
            Capsule().fill(event.color).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(Theme.Font.headline)
                    .lineLimit(1)
                if let location = event.location {
                    Text(location)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let url = event.joinURL {
                ChipButton(title: "Join", systemImage: "video.fill", tint: Palette.green) { NSWorkspace.shared.open(url) }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(live ? Palette.green.opacity(0.08) : Theme.surface))
    }
}

struct DueRow: View {
    let item: DueItem

    var body: some View {
        let overdue = item.due < Date()
        let urgent = item.due.timeIntervalSinceNow < 24 * 3600
        let accent = overdue ? Palette.red : (urgent ? Palette.amber : Theme.inkSecondary)
        HStack(spacing: 10) {
            Circle()
                .strokeBorder(overdue ? Palette.red : item.color, lineWidth: 1.5)
                .frame(width: 13, height: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(Theme.Font.headline)
                    .lineLimit(1)
                Text(item.source)
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.inkTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(IslandModel.relative(item.due).capitalizedFirst)
                .font(Theme.Font.number)
                .foregroundStyle(accent)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(Theme.surface))
    }
}

// MARK: - Activity

struct ActivityList: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let connected = model.serverStatus.hasPrefix("listening")
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                SectionTitle(title: "Activity", count: model.activities.count)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(connected ? Palette.green : Palette.red)
                        .frame(width: 5, height: 5)
                    Text(connected ? "Cove online" : model.serverStatus)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.inkTertiary)
                }
                .help(model.serverStatus)
            }
            if model.activities.isEmpty && model.history.isEmpty {
                VStack(spacing: 8) {
                    if model.config.buddy {
                        Buddy(mood: .sleepy, size: 34)
                    } else {
                        Image(systemName: "sparkles")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(Theme.inkTertiary)
                    }
                    Text("All caught up")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .multilineTextAlignment(.center)
                    Text("Agent updates and notifications appear here")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.inkTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Theme.Space.l)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Color.white.opacity(0.03)))
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 6) {
                        ForEach(model.activities) { activity in
                            ActivityRow(activity: activity) { model.open(activity) }
                        }
                        if !model.history.isEmpty {
                            HStack {
                                SectionTitle(title: "Earlier")
                                Spacer()
                            }
                            .padding(.top, model.activities.isEmpty ? 0 : 6)
                            ForEach(model.history.prefix(8)) { banner in
                                HistoryRow(banner: banner) { model.tapBanner(banner) }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct ActivityRow: View {
    let activity: Activity
    var onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            AgentTile(agent: activity.agent, animating: activity.state == .running, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(activity.title)
                        .font(Theme.Font.headline)
                        .lineLimit(1)
                    if !activity.seen {
                        Circle().fill(Palette.green).frame(width: 6, height: 6)
                            .transition(.scale.combined(with: .opacity))
                    }
                    Spacer(minLength: 4)
                    timeLabel
                        .font(.system(size: 10.5, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(Theme.inkTertiary)
                }
                HStack(spacing: 6) {
                    statusBadge
                    if activity.id.hasPrefix("web:") || activity.id.hasPrefix("desktop:") {
                        Text(activity.originLabel).font(.system(size: 9)).foregroundStyle(Theme.inkTertiary)
                    }
                    Text(activity.detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkSecondary)
                        .lineLimit(1)
                }
                if let progress = activity.progress, activity.state == .running {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule()
                                .fill(activity.agent.tint)
                                .frame(width: geo.size.width * min(max(progress, 0), 1))
                        }
                    }
                    .frame(height: 3)
                    .padding(.top, 2)
                    .animation(Theme.snappy, value: progress)
                }
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.inkTertiary)
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
                .fill(activity.state == .attention ? Palette.amber.opacity(0.1) : (hovering ? Theme.surfaceRaised : Theme.surface))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
        .help(helpText)
        .animation(Theme.snappy, value: activity.state)
        .animation(Theme.snappy, value: activity.seen)
    }

    private var helpText: String {
        guard let owner = activity.ownerApp else { return "" }
        return "Jump back to \(AppIcons.name(for: owner))"
    }

    @ViewBuilder
    private var timeLabel: some View {
        if activity.isLive {
            Text(activity.startedAt, style: .timer)
        } else if let finished = activity.finishedAt {
            Text(finished, style: .relative)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch activity.state {
        case .running:
            if let progress = activity.progress {
                Text("\(Int(progress * 100))%")
                    .font(Theme.Font.number)
                    .foregroundStyle(activity.agent.tint)
            } else {
                ArcSpinner(color: activity.agent.tint, size: 10)
            }
        case .attention:
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Palette.amber)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Palette.red)
        }
    }
}

struct HistoryRow: View {
    let banner: Banner
    var onTap: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            BannerIconView(icon: banner.icon, size: 24)
                .padding(.leading, 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(banner.title)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .lineLimit(1)
                if !banner.body.isEmpty {
                    Text(banner.body)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(banner.date, style: .relative)
                .font(.system(size: 10.5, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.inkTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(hovering ? Theme.surface : Color.clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onTap)
    }
}

// MARK: - Shelf

struct ShelfPane: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if model.shelf.isEmpty {
            DropZone(targeted: model.isDropTargeted)
        } else {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    SectionTitle(title: "Shelf", count: model.shelf.count)
                    Spacer()
                    Text("Saved until you remove them")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.inkTertiary)
                    ChipButton(title: "Clear", systemImage: "trash") { model.clearShelf() }
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                        ForEach(model.shelf, id: \.self) { url in
                            ShelfItem(url: url, model: model)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 2)
                }
                .frame(maxHeight: .infinity)
                .accessibilityIdentifier("shelf.items")
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                        .strokeBorder(Palette.blue.opacity(model.isDropTargeted ? 0.7 : 0), lineWidth: 1.5)
                )
            }
        }
    }
}

private struct DropZone: View {
    let targeted: Bool

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: targeted ? "tray.and.arrow.down.fill" : "tray.and.arrow.down")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(targeted ? Palette.blue : Theme.inkTertiary)
                .symbolEffect(.bounce, value: targeted)
            Text(targeted ? "Drop to keep it here" : "Drop files on the notch to keep them handy")
                .font(Theme.Font.headline)
            Text("Screenshots land here automatically. Drag anything back out into any app.")
                .font(Theme.Font.caption)
                .foregroundStyle(Theme.inkTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .fill(targeted ? Palette.blue.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(targeted ? Palette.blue.opacity(0.8) : Color.white.opacity(0.16),
                              style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
        )
        .animation(Theme.snappy, value: targeted)
    }
}

struct ShelfItem: View {
    let url: URL
    @ObservedObject var model: IslandModel
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 6) {
            FileThumbnail(url: url, size: 56)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.thumb, style: .continuous))
                .shadow(color: .black.opacity(hovering ? 0.5 : 0), radius: 6, y: 3)
            Text(url.lastPathComponent)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.inkSecondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .frame(width: 80)
            if !FileManager.default.fileExists(atPath: url.path) {
                Text("Unavailable").font(.system(size: 9)).foregroundStyle(Palette.amber)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous).fill(hovering ? Theme.surfaceRaised : Theme.surface))
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button {
                    model.removeFromShelf(url)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.black)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.85)))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel("Remove \(url.lastPathComponent) from shelf")
                .offset(x: 4, y: -4)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .offset(y: hovering ? -2 : 0)
        .animation(Theme.snappy, value: hovering)
        .onHover { hovering = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .help(url.path)
        .accessibilityIdentifier("shelf.item.\(url.lastPathComponent)")
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Copy") { model.copyToPasteboard(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Remove from Shelf") { model.removeFromShelf(url) }
        }
    }
}

extension String {
    /// "in 12 min" → "In 12 min", for text that starts a line.
    var capitalizedFirst: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }
}
